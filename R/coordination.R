# --- Multi-Agent Coordination v2 ---
# An append-only, typed, on-disk event log replacing the shared-dataframe
# message board. Design driven by field reports from real multi-hour
# multi-agent sessions:
#   - typed events instead of prose-grepping ("KIT_READY" as a signal field,
#     not a substring)
#   - append-only log + per-agent cursors: no shared row is ever mutated, so
#     the rbind/clobber race is structurally impossible
#   - to-addressing and reply threading
#   - presence auto-stamped by every write
#   - survives R restarts (the log lives on disk, one JSON object per line)
# The Python bridge reads and writes the same file directly, so a busy R
# session never blocks coordination, and wait_for_message can long-poll
# without touching R.

coord_dir <- function(session = NULL) {
  if (is.null(session)) {
    session <- .claude_server_env$session_name
    if (is.null(session) || !nzchar(session)) session <- "default"
  }
  d <- file.path(path.expand("~"), ".clauder_coord",
                 gsub("[^a-zA-Z0-9_-]", "_", session))
  if (!dir.exists(d)) dir.create(d, recursive = TRUE, mode = "0700")
  d
}

coord_log_path <- function(session = NULL) file.path(coord_dir(session), "events.jsonl")

# The calling agent's identity. execute_code_in_session() sets
# CLAUDER_AGENT_ID around each evaluation, so agent code gets correct
# attribution with no arguments; humans at the console default to "user".
coord_agent <- function(agent = NULL) {
  if (!is.null(agent) && nzchar(agent)) return(agent)
  env_id <- Sys.getenv("CLAUDER_AGENT_ID", "")
  if (nzchar(env_id)) env_id else "user"
}

# Append one event. Single-line O_APPEND writes of this size are atomic on
# POSIX, which is what makes the lock-free append-only design safe.
coord_append <- function(type, body = list(), to = "all", reply_to = NA,
                         agent = NULL, session = NULL) {
  ev <- list(
    ts = format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3"),
    from = coord_agent(agent),
    type = type,
    to = to,
    body = body
  )
  if (!is.na(reply_to)) ev$reply_to <- as.integer(reply_to)
  line <- jsonlite::toJSON(ev, auto_unbox = TRUE, null = "null")
  if (nchar(line) > 4000) {
    stop("Coordination event too large (> 4000 chars). Put bulky content in a file and send the path.",
         call. = FALSE)
  }
  con <- file(coord_log_path(session), open = "a")
  on.exit(close(con), add = TRUE)
  writeLines(line, con)
  invisible(NULL)
}

# Read the full event log. Event ids are line numbers: monotonic, assigned
# by position, never reused.
coord_events <- function(session = NULL) {
  p <- coord_log_path(session)
  if (!file.exists(p)) return(list())
  lines <- readLines(p, warn = FALSE)
  lines <- lines[nzchar(lines)]
  evs <- lapply(seq_along(lines), function(i) {
    ev <- tryCatch(jsonlite::fromJSON(lines[i], simplifyVector = FALSE),
                   error = function(e) NULL)
    if (!is.null(ev)) ev$id <- i
    ev
  })
  evs[!vapply(evs, is.null, logical(1))]
}

cursor_path <- function(agent, session = NULL) {
  file.path(coord_dir(session),
            paste0("cursor_", gsub("[^a-zA-Z0-9_-]", "_", agent), ".txt"))
}

coord_cursor <- function(agent, session = NULL) {
  p <- cursor_path(agent, session)
  if (!file.exists(p)) return(0L)
  v <- suppressWarnings(as.integer(readLines(p, n = 1, warn = FALSE)))
  if (is.na(v)) 0L else v
}

#' Send a typed message to other agents
#'
#' Appends a typed event to the session's shared coordination log. Types are
#' free-form but agents should stick to a small vocabulary: `"message"`
#' (prose), `"signal"` (machine-checkable, e.g. `body = list(name = "KIT_READY",
#' tile = "3094,3493")`), `"status"`, `"handoff"`, `"question"`.
#'
#' @param body A string (becomes `list(text = body)`) or a named list payload.
#' @param to Recipient agent id, or `"all"` (default).
#' @param type Event type. Default `"message"`.
#' @param reply_to Optional id of the event this answers (threading).
#' @param agent Sender identity; defaults to the executing agent.
#' @param session Session name; defaults to the active session.
#' @return Invisibly, NULL.
#' @export
cr_send <- function(body, to = "all", type = "message", reply_to = NA,
                    agent = NULL, session = NULL) {
  if (is.character(body) && length(body) == 1) body <- list(text = body)
  coord_append(type = type, body = body, to = to, reply_to = reply_to,
               agent = agent, session = session)
  invisible(NULL)
}

#' Read unread coordination events for an agent
#'
#' Returns events addressed to this agent (or to `"all"`) that arrived after
#' the agent's cursor, excluding its own. Advance the cursor with [cr_ack()].
#'
#' @param agent Reader identity; defaults to the executing agent.
#' @param session Session name; defaults to the active session.
#' @param include_heartbeats Include heartbeat events. Default FALSE.
#' @return A data.frame with id, ts, from, type, to, reply_to, and body (JSON).
#' @export
cr_inbox <- function(agent = NULL, session = NULL, include_heartbeats = FALSE) {
  me <- coord_agent(agent)
  cur <- coord_cursor(me, session)
  evs <- coord_events(session)
  keep <- Filter(function(e) {
    e$id > cur && !identical(e$from, me) &&
      (identical(e$to, "all") || identical(e$to, me)) &&
      (include_heartbeats || !identical(e$type, "heartbeat"))
  }, evs)
  if (length(keep) == 0) {
    return(data.frame(id = integer(0), ts = character(0), from = character(0),
                      type = character(0), to = character(0),
                      reply_to = integer(0), body = character(0),
                      stringsAsFactors = FALSE))
  }
  do.call(rbind, lapply(keep, function(e) data.frame(
    id = e$id, ts = e$ts, from = e$from, type = e$type, to = e$to,
    reply_to = if (is.null(e$reply_to)) NA_integer_ else e$reply_to,
    body = as.character(jsonlite::toJSON(e$body, auto_unbox = TRUE)),
    stringsAsFactors = FALSE
  )))
}

#' Acknowledge coordination events up to an id
#'
#' Advances only the calling agent's own cursor file; no shared state is
#' modified, so concurrent acks by different agents cannot conflict.
#'
#' @param through_id Highest event id now considered read.
#' @param agent Reader identity; defaults to the executing agent.
#' @param session Session name; defaults to the active session.
#' @return Invisibly, the new cursor value.
#' @export
cr_ack <- function(through_id, agent = NULL, session = NULL) {
  me <- coord_agent(agent)
  writeLines(as.character(as.integer(through_id)), cursor_path(me, session))
  invisible(as.integer(through_id))
}

#' Set or read shared facts (latest-wins key-value store)
#'
#' Facts hold coordination state that must not live in prose: account
#' ownership, resource coordinates, phase markers.
#'
#' @param key Fact name.
#' @param value Value to record; omit to read all current facts.
#' @param agent,session See [cr_send()].
#' @return `cr_fact(key, value)` invisibly NULL; `cr_facts()` a named list of
#'   the latest value per key.
#' @export
cr_fact <- function(key, value, agent = NULL, session = NULL) {
  coord_append("fact", body = list(key = key, value = value),
               agent = agent, session = session)
  invisible(NULL)
}

#' @rdname cr_fact
#' @export
cr_facts <- function(session = NULL) {
  evs <- coord_events(session)
  out <- list()
  for (e in evs) {
    if (identical(e$type, "fact") && !is.null(e$body$key)) {
      out[[e$body$key]] <- e$body$value
    }
  }
  out
}

#' Claim, release, or complete a task with a lease
#'
#' Claims are lease-based: a claim by another agent blocks yours until its
#' lease expires or it is released/completed. Renew by re-claiming.
#'
#' @param task Task identifier string.
#' @param lease_s Lease duration in seconds. Default 900 (15 minutes).
#' @param note Optional completion note recorded by `cr_done()`.
#' @param agent,session See [cr_send()].
#' @return For `cr_claim`: TRUE if the claim succeeded, otherwise FALSE with
#'   the current holder in a message.
#' @export
cr_claim <- function(task, lease_s = 900, agent = NULL, session = NULL) {
  me <- coord_agent(agent)
  st <- claim_state(task, session)
  if (!is.null(st) && !identical(st$holder, me) && st$valid) {
    message(sprintf("Task '%s' is held by %s (lease expires %s).",
                    task, st$holder, st$expires))
    return(invisible(FALSE))
  }
  coord_append("claim", body = list(task = task, lease_s = lease_s),
               agent = me, session = session)
  invisible(TRUE)
}

#' @rdname cr_claim
#' @export
cr_release <- function(task, agent = NULL, session = NULL) {
  coord_append("release", body = list(task = task), agent = agent, session = session)
  invisible(NULL)
}

#' @rdname cr_claim
#' @export
cr_done <- function(task, note = "", agent = NULL, session = NULL) {
  coord_append("done", body = list(task = task, note = note),
               agent = agent, session = session)
  invisible(NULL)
}

claim_state <- function(task, session = NULL) {
  evs <- coord_events(session)
  st <- NULL
  for (e in evs) {
    if (is.null(e$body$task) || !identical(e$body$task, task)) next
    if (identical(e$type, "claim")) {
      lease <- if (is.null(e$body$lease_s)) 900 else as.numeric(e$body$lease_s)
      exp <- as.POSIXct(e$ts, format = "%Y-%m-%dT%H:%M:%OS") + lease
      st <- list(holder = e$from, expires = format(exp),
                 valid = Sys.time() < exp, done = FALSE)
    } else if (identical(e$type, "release") || identical(e$type, "done")) {
      st <- NULL
    }
  }
  st
}

#' List agents seen on the coordination log with staleness
#'
#' Presence is stamped by every event an agent writes, so liveness does not
#' depend on agents remembering to heartbeat. [cr_ping()] exists for agents
#' that have nothing to say.
#'
#' @param stale_after_s Seconds after which an agent is flagged stale.
#' @param agent Identity stamped by `cr_ping()`; defaults to the executing agent.
#' @param session Session name; defaults to the active session.
#' @return data.frame of agent, last_seen, seconds_ago, stale.
#' @export
cr_roster <- function(stale_after_s = 900, session = NULL) {
  evs <- coord_events(session)
  if (length(evs) == 0) {
    return(data.frame(agent = character(0), last_seen = character(0),
                      seconds_ago = numeric(0), stale = logical(0),
                      stringsAsFactors = FALSE))
  }
  last <- list()
  for (e in evs) last[[e$from]] <- e$ts
  out <- do.call(rbind, lapply(names(last), function(a) {
    t <- as.POSIXct(last[[a]], format = "%Y-%m-%dT%H:%M:%OS")
    ago <- as.numeric(difftime(Sys.time(), t, units = "secs"))
    data.frame(agent = a, last_seen = last[[a]],
               seconds_ago = round(ago), stale = ago > stale_after_s,
               stringsAsFactors = FALSE)
  }))
  out[order(out$seconds_ago), ]
}

#' @rdname cr_roster
#' @export
cr_ping <- function(agent = NULL, session = NULL) {
  coord_append("heartbeat", body = list(), agent = agent, session = session)
  invisible(NULL)
}

# ---- Consensus gate -------------------------------------------------------

CONSENSUS_SENTENCE <- "I CONFIRM I HAVE READ THEIR SUGGESTION AND WE HAVE BOTH REACHED AN AGREEMENT TO MOVE FORWARD"

CONSENSUS_BANNER <- paste(
  "AGREEMENT NOT REACHED PLEASE STOP AND CONFIRM YOU AND YOUR PARTNER BOTH AGREE BEFORE CONTINUING",
  "IF YOU BOTH AGREE YOU MUST BOTH WRITE 'I CONFIRM I HAVE READ THEIR SUGGESTION AND WE HAVE BOTH REACHED AN AGREEMENT TO MOVE FORWARD'",
  "DO NOT CONFIRM THIS IF IT IS NOT TRUE.",
  sep = "\n"
)

#' Propose a plan requiring explicit multi-agent consensus
#'
#' Arms the consensus gate. Until `required` distinct agents have each
#' written the confirmation sentence verbatim via [confirm_agreement()],
#' every code execution response in the session carries a banner demanding
#' the confirmation. The proposer must confirm too: proposing does not imply
#' having read the partner's response.
#'
#' @param text The plan text.
#' @param required Number of distinct agents that must confirm. Default 2.
#' @param agent,session See [cr_send()].
#' @return Invisibly, NULL.
#' @export
propose_plan <- function(text, required = 2L, agent = NULL, session = NULL) {
  coord_append("proposal", body = list(text = text, required = as.integer(required)),
               agent = agent, session = session)
  message("Plan proposed. Consensus gate ARMED: every execution response will ",
          "carry the confirmation banner until ", required,
          " distinct agents run confirm_agreement() with the exact sentence.")
  invisible(NULL)
}

#' Confirm agreement with the currently proposed plan
#'
#' The statement must match the required sentence exactly. Do not confirm
#' unless you have actually read your partner's latest position and agree.
#'
#' @param statement Must be exactly:
#'   `"I CONFIRM I HAVE READ THEIR SUGGESTION AND WE HAVE BOTH REACHED AN AGREEMENT TO MOVE FORWARD"`
#' @param agent,session See [cr_send()].
#' @return Invisibly, TRUE when the confirmation is recorded.
#' @export
confirm_agreement <- function(statement, agent = NULL, session = NULL) {
  if (!identical(statement, CONSENSUS_SENTENCE)) {
    stop("Confirmation rejected: the statement must be exactly:\n'",
         CONSENSUS_SENTENCE, "'\nDO NOT CONFIRM THIS IF IT IS NOT TRUE.",
         call. = FALSE)
  }
  st <- consensus_state(session)
  if (is.null(st)) {
    stop("No plan has been proposed. Use propose_plan() first.", call. = FALSE)
  }
  coord_append("confirm", body = list(proposal_id = st$proposal_id),
               agent = agent, session = session)
  st <- consensus_state(session)
  if (st$approved) {
    message("CONSENSUS REACHED: plan approved by ",
            paste(st$confirmed_by, collapse = ", "),
            ". The banner is disarmed.")
  } else {
    message("Confirmation recorded (", length(st$confirmed_by), "/",
            st$required, "). Waiting on the other agent(s).")
  }
  invisible(TRUE)
}

#' @rdname propose_plan
#' @export
revoke_plan <- function(agent = NULL, session = NULL) {
  coord_append("proposal_revoked", body = list(), agent = agent, session = session)
  message("Plan revoked; consensus gate disarmed.")
  invisible(NULL)
}

#' @rdname propose_plan
#' @export
consensus_status <- function(session = NULL) {
  st <- consensus_state(session)
  if (is.null(st)) {
    cat("No active plan proposal.\n")
    return(invisible(NULL))
  }
  cat(sprintf("Plan (event %d) proposed by %s: %s\nConfirmed by: %s (%d/%d)\nStatus: %s\n",
              st$proposal_id, st$proposer,
              substr(st$text, 1, 200),
              if (length(st$confirmed_by)) paste(st$confirmed_by, collapse = ", ") else "none",
              length(st$confirmed_by), st$required,
              if (st$approved) "APPROVED" else "PENDING - banner armed"))
  invisible(st)
}

# Fold the log into the current consensus state. NULL when no live proposal.
consensus_state <- function(session = NULL) {
  evs <- coord_events(session)
  prop <- NULL
  confirms <- character(0)
  for (e in evs) {
    if (identical(e$type, "proposal")) {
      prop <- e
      confirms <- character(0)
    } else if (identical(e$type, "proposal_revoked")) {
      prop <- NULL
      confirms <- character(0)
    } else if (identical(e$type, "confirm") && !is.null(prop) &&
               identical(as.integer(e$body$proposal_id), as.integer(prop$id))) {
      confirms <- unique(c(confirms, e$from))
    }
  }
  if (is.null(prop)) return(NULL)
  required <- if (is.null(prop$body$required)) 2L else as.integer(prop$body$required)
  list(proposal_id = prop$id, proposer = prop$from,
       text = if (is.null(prop$body$text)) "" else prop$body$text,
       required = required, confirmed_by = confirms,
       approved = length(confirms) >= required)
}

# Cheap banner check for the execution hot path: re-fold only when the log
# file has changed since the last check.
.claude_consensus_cache <- new.env(parent = emptyenv())

consensus_banner_needed <- function(session = NULL) {
  p <- coord_log_path(session)
  if (!file.exists(p)) return(FALSE)
  info <- file.info(p)
  key <- paste0(info$size, "_", as.numeric(info$mtime))
  if (identical(.claude_consensus_cache$key, key)) {
    return(isTRUE(.claude_consensus_cache$needed))
  }
  st <- consensus_state(session)
  needed <- !is.null(st) && !st$approved
  .claude_consensus_cache$key <- key
  .claude_consensus_cache$needed <- needed
  needed
}

# --- Human observability -----------------------------------------------
# Coordination deliberately bypasses R so a busy session cannot block
# messaging. The cost is that the human sees nothing in the console or the
# addin. These helpers let the addin's refresh loop surface the traffic.

# Rendering of a coordination event for console and log display. Full body,
# never truncated: the human watching the console is the audience of record,
# and a cut-off message is worse than a long one (bodies are capped at 4000
# chars at write time anyway).
format_coord_event <- function(e) {
  body_txt <- tryCatch({
    if (is.list(e$body) && !is.null(e$body$text)) as.character(e$body$text)
    else as.character(jsonlite::toJSON(e$body, auto_unbox = TRUE))
  }, error = function(err) "")
  sprintf("[%s] %s -> %s (%s): %s",
          substr(e$ts, 12, 19), e$from, e$to, e$type, body_txt)
}

# Compact presence summary from the event log: who has written, how long ago.
coord_roster_text <- function(session = NULL, stale_after = 900) {
  evs <- tryCatch(coord_events(session), error = function(err) list())
  if (length(evs) == 0) return(NULL)
  last <- list()
  for (e in evs) if (!is.null(e$from)) last[[e$from]] <- e$ts
  now <- Sys.time()
  parts <- vapply(names(last), function(nm) {
    ts <- suppressWarnings(as.POSIXct(last[[nm]], format = "%Y-%m-%dT%H:%M:%OS"))
    if (is.na(ts)) return(sprintf("%s (?)", nm))
    ago <- round(as.numeric(difftime(now, ts, units = "secs")))
    sprintf("%s (%ss ago%s)", nm, ago, if (ago > stale_after) ", STALE" else "")
  }, character(1))
  paste(parts, collapse = ", ")
}
