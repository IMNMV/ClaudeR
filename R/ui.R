# --- Discovery File System ---
# Allows Python MCP servers to discover active R sessions dynamically.
# Resolved at call time so each user gets their own home directory, even when
# the package was installed system-wide by a different account (e.g. root on
# RStudio Server).
#
# On Windows, R's path.expand("~") can resolve to Documents (via R_USER) or to
# a OneDrive-synced folder (when HOME is set, which is increasingly common in
# Microsoft 365 setups). Python's os.path.expanduser("~") on Windows ignores
# HOME entirely and uses USERPROFILE, so R and Python disagree on where the
# discovery file lives. Match Python by always using USERPROFILE on Windows,
# regardless of what HOME or R_USER point at.

discovery_dir <- function() {
  base <- if (.Platform$OS.type == "windows") {
    Sys.getenv("USERPROFILE", unset = path.expand("~"))
  } else {
    path.expand("~")
  }
  file.path(base, ".claude_r_sessions")
}

# The discovery file doubles as the shared-secret channel between R and the
# Python MCP bridge: the bridge reads `token` and echoes it back in the
# X-Clauder-Token header. Written 0600 so other local users cannot read it.
generate_session_token <- function() {
  # Prefer OS entropy: unguessable, and touches nothing in the R session.
  # /dev/urandom exists on macOS and Linux.
  bytes <- tryCatch({
    con <- file("/dev/urandom", "rb")
    on.exit(close(con), add = TRUE)
    readBin(con, "raw", 32L)
  }, error = function(e) NULL, warning = function(w) NULL)
  if (!is.null(bytes) && length(bytes) == 32L) {
    return(paste(sprintf("%02x", as.integer(bytes)), collapse = ""))
  }

  # Fallback (Windows): time/pid-seeded RNG. Must not disturb the caller's
  # RNG stream -- this is a reproducibility tool, and silently advancing
  # .Random.seed when the server starts would change the results of any
  # subsequent set.seed()-less simulation. Snapshot, reseed, then put the
  # user's stream back exactly as we found it.
  had_seed <- exists(".Random.seed", envir = globalenv(), inherits = FALSE)
  old_seed <- if (had_seed) get(".Random.seed", envir = globalenv()) else NULL
  on.exit({
    if (had_seed) {
      assign(".Random.seed", old_seed, envir = globalenv())
    } else if (exists(".Random.seed", envir = globalenv(), inherits = FALSE)) {
      rm(".Random.seed", envir = globalenv())
    }
  }, add = TRUE)

  set.seed(NULL)  # reseed from time/pid entropy
  paste(sprintf("%02x", sample.int(256L, 32L, replace = TRUE) - 1L), collapse = "")
}

write_discovery_file <- function(session_name, port, token) {
  d <- discovery_dir()
  if (!dir.exists(d)) dir.create(d, recursive = TRUE, mode = "0700")
  info <- list(
    session_name = session_name,
    port = port,
    pid = Sys.getpid(),
    token = token,
    started_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
  )
  f <- file.path(d, paste0(session_name, ".json"))
  # Two live sessions sharing a name would silently clobber each other's
  # discovery file, and agents would then be routed to one of them holding the
  # other's token. Port reuse is already caught loudly; this was not.
  if (file.exists(f)) {
    other <- tryCatch(jsonlite::fromJSON(f), error = function(e) NULL)
    if (!is.null(other) && !identical(as.integer(other$pid), Sys.getpid()) &&
        pid_is_alive(other$pid)) {
      warning(sprintf(paste0("Another live R session is already registered as '%s' ",
                             "(pid %s, port %s). Give this session a different name, ",
                             "or agents may be routed to the wrong one."),
                      session_name, other$pid, other$port), call. = FALSE)
    }
  }
  jsonlite::write_json(info, f, auto_unbox = TRUE, pretty = TRUE)
  try(Sys.chmod(f, mode = "0600"), silent = TRUE)
}

remove_discovery_file <- function(session_name) {
  f <- file.path(discovery_dir(), paste0(session_name, ".json"))
  if (file.exists(f)) file.remove(f)
}

# Is a process alive? Must never kill it.
#
# tools::pskill(pid, signal = 0) is the usual idiom, and it is safe on Unix
# where it maps to kill(pid, 0). On Windows it is NOT: ?tools::pskill states
# that only SIGINT and SIGTERM exist there and that pskill "will always use the
# Windows system call TerminateProcess". Using it as a liveness probe therefore
# terminated the very session it was asking about, and returned TRUE for the
# kill, so the discovery file was then judged live and left behind.
pid_is_alive <- function(pid) {
  pid <- suppressWarnings(as.integer(pid))
  if (is.na(pid) || pid <= 0) return(FALSE)
  if (.Platform$OS.type == "windows") {
    # tasklist ships with Windows, so this needs no extra package.
    out <- tryCatch(
      suppressWarnings(system2("tasklist",
                               c("/FI", shQuote(sprintf("PID eq %d", pid)), "/NH"),
                               stdout = TRUE, stderr = NULL)),
      error = function(e) character(0)
    )
    return(any(grepl(paste0("\\b", pid, "\\b"), out)))
  }
  isTRUE(tryCatch(tools::pskill(pid, signal = 0), error = function(e) FALSE))
}

cleanup_stale_discovery_files <- function() {
  d <- discovery_dir()
  if (!dir.exists(d)) return(invisible(NULL))
  files <- list.files(d, pattern = "\\.json$", full.names = TRUE)
  for (f in files) {
    tryCatch({
      info <- jsonlite::fromJSON(f)
      if (!pid_is_alive(info$pid)) file.remove(f)
    }, error = function(e) {
      # Corrupted file, remove it
      file.remove(f)
    })
  }
  invisible(NULL)
}

# --- Plot Draw Detection ---
# Comparing recordPlot() snapshots before/after eval cannot distinguish
# "redrew the same figure" from "drew nothing": both leave a byte-identical
# display list. A genuine redraw is therefore misread as stale and the agent
# silently stops receiving images from the third identical redraw onward.
#
# Drawing *events* answer the question the snapshot comparison cannot.
# plot.new()/grid.newpage() fire on every new plot; the rest fire when code
# adds to an existing one. Tracing is installed once per session rather than
# per call, so it costs nothing on the hot path -- which also lets us drop the
# two recordPlot() deep-copies that previously ran on every single execution,
# including calls that touch no graphics at all.
.claude_plot_env <- new.env(parent = emptyenv())
.claude_plot_env$drew <- FALSE
.claude_plot_env$devs <- integer(0)   # device ids drawn on during the current execution
.claude_plot_env$traced <- NULL

.claude_draw_fns <- list(
  graphics = c("plot.new", "plot.xy", "abline", "text.default", "mtext",
               "title", "axis", "box", "legend", "rect", "polygon",
               "segments", "arrows"),
  grid     = c("grid.newpage", "grid.draw")
)

install_draw_tracers <- function() {
  if (!is.null(.claude_plot_env$traced)) return(invisible(.claude_plot_env$traced))

  # The tracer is evaluated inside the traced function's own namespace, so it
  # cannot reference names defined here. bquote() splices the environment
  # object itself into the call, making it self-contained wherever it runs.
  # It records *which device* was drawn on: a draw event alone cannot tell a
  # screen plot from `png(...); plot(...); dev.off()`, and capturing after a
  # file-device-only draw would resend whatever old figure the screen holds.
  tracer <- bquote({
    .e <- .(.claude_plot_env)
    .e$drew <- TRUE
    .e$devs <- unique(c(.e$devs, grDevices::dev.cur()))
  })

  installed <- list()
  for (pkg in names(.claude_draw_fns)) {
    if (!requireNamespace(pkg, quietly = TRUE)) next

    # Both bindings must be traced. The namespace binding catches internal
    # calls (points() -> plot.xy()); the attached package binding catches the
    # user's top-level calls. Tracing only the namespace silently misses
    # abline(), which reaches the device via .External.graphics() without
    # passing through any other traced function.
    envs <- list(asNamespace(pkg))
    attached <- paste0("package:", pkg)
    if (attached %in% search()) envs <- c(envs, list(as.environment(attached)))

    for (fn in .claude_draw_fns[[pkg]]) {
      for (env in envs) {
        ok <- tryCatch({
          suppressMessages(trace(fn, tracer = tracer, print = FALSE, where = env))
          TRUE
        }, error = function(e) FALSE)
        if (ok) installed[[length(installed) + 1L]] <- list(fn = fn, where = env)
      }
    }
  }
  .claude_plot_env$traced <- installed
  invisible(installed)
}

remove_draw_tracers <- function() {
  tr <- .claude_plot_env$traced
  if (!is.null(tr)) {
    for (t in tr) {
      try(suppressMessages(untrace(t$fn, where = t$where)), silent = TRUE)
    }
  }
  .claude_plot_env$traced <- NULL
  invisible(NULL)
}

.onUnload <- function(libpath) {
  remove_draw_tracers()
}

# TRUE when the current device is a screen device we can meaningfully
# dev.copy() from. File devices (png, pdf, ...) either keep no display list
# or hold content the code is deliberately writing elsewhere.
is_screen_device <- function() {
  if (is.null(grDevices::dev.list())) return(FALSE)
  dn <- names(grDevices::dev.cur())
  identical(dn, "RStudioGD") || isTRUE(dn %in% grDevices::deviceIsInteractive())
}

# --- Agent History Environment ---
# Package-level environment for tracking per-agent execution history.
.claude_history_env <- new.env(parent = emptyenv())
.claude_history_env$entries <- list()
.claude_history_env$max_entries <- 500L

# --- Viewer Tracking ---
# Wraps RStudio's viewer to capture the last URL displayed.
.claude_viewer_env <- new.env(parent = emptyenv())
.claude_viewer_env$last_url <- NULL
.claude_viewer_env$original_viewer <- NULL
.claude_viewer_env$suppress <- FALSE

wrap_viewer <- function() {
  # Don't double-wrap -- if we already saved the original, skip

  if (!is.null(.claude_viewer_env$original_viewer)) return(invisible())
  orig <- getOption("viewer")
  if (is.function(orig)) {
    .claude_viewer_env$original_viewer <- orig
    options(viewer = function(url, height = NULL) {
      .claude_viewer_env$last_url <- url
      if (isTRUE(.claude_viewer_env$suppress)) {
        # Agent execution: open in browser instead of stealing the viewer pane
        # Ensure file:// prefix so browser can load local temp files
        if (file.exists(url) && !grepl("^(http|file):", url)) {
          url <- paste0("file://", normalizePath(url, winslash = "/"))
        }
        utils::browseURL(url)
      } else {
        .claude_viewer_env$original_viewer(url, height)
      }
    })
  }
}

unwrap_viewer <- function() {
  if (!is.null(.claude_viewer_env$original_viewer)) {
    options(viewer = .claude_viewer_env$original_viewer)
    .claude_viewer_env$original_viewer <- NULL
  }
}

# --- Server State ---
# Package-level state that persists across addin UI restarts.
.claude_server_env <- new.env(parent = emptyenv())
.claude_server_env$server <- NULL
.claude_server_env$running <- FALSE
.claude_server_env$port <- NULL
.claude_server_env$session_name <- NULL
.claude_server_env$execution_count <- 0L
.claude_server_env$token <- NULL

# --- Background Jobs (callr) ---
# Package-level environment for non-blocking async execution.
.claude_bg_jobs <- new.env(parent = emptyenv())

#' Start a background R job via callr
#' @param code R code to execute in a separate process
#' @param job_id Unique identifier for the job
#' @param settings ClaudeR settings list
#' @param agent_id Optional agent identifier
#' @param input_names Optional character vector of object names to copy from the
#'   main session into the background process before running `code`.
#' @param output_names Optional character vector of object names the background
#'   process will create that should be loaded back into the main session when
#'   the job completes.
start_background_job <- function(code, job_id, settings = NULL, agent_id = NULL,
                                  input_names = character(0), output_names = character(0)) {
  if (is.null(settings)) settings <- load_claude_settings()

  # Security check
  validation <- validate_code_security(code)
  if (validation$blocked) {
    return(list(success = FALSE, error = validation$reason))
  }

  # Marshal inputs from the main session to a tempfile (snapshot at submit time).
  inputs_path <- NULL
  if (length(input_names) > 0) {
    missing_inputs <- input_names[!vapply(input_names, exists, logical(1), envir = .GlobalEnv, inherits = FALSE)]
    if (length(missing_inputs) > 0) {
      return(list(success = FALSE, error = sprintf(
        "Input objects not found in main session: %s",
        paste(missing_inputs, collapse = ", ")
      )))
    }
    inputs_list <- mget(input_names, envir = .GlobalEnv)
    inputs_path <- tempfile(pattern = paste0("clauder_async_in_", job_id, "_"), fileext = ".rds")
    saveRDS(inputs_list, inputs_path)
  }

  outputs_path <- if (length(output_names) > 0) {
    tempfile(pattern = paste0("clauder_async_out_", job_id, "_"), fileext = ".rds")
  } else NULL

  # Log / print
  if (settings$print_to_console) {
    agent_label <- if (!is.null(agent_id)) paste0(" [", agent_id, "]") else ""
    cat(sprintf("\n### LLM%s submitted async job %s ###\n", agent_label, job_id))
    cat(code, "\n")
    cat("### End of async job code ###\n\n")
  }
  if (settings$log_to_file && !is.null(settings$log_file_path) && settings$log_file_path != "") {
    log_code_to_file(paste0("# [ASYNC JOB ", job_id, "]\n", code), settings$log_file_path, agent_id = agent_id)
  }

  # Launch in a separate R process (skip .Rprofile to avoid startup noise in stderr)
  job <- callr::r_bg(function(code, inputs_path, outputs_path, output_names) {
    work_env <- new.env(parent = globalenv())

    if (!is.null(inputs_path) && file.exists(inputs_path)) {
      .clauder_inputs <- readRDS(inputs_path)
      list2env(.clauder_inputs, envir = work_env)
    }

    output_lines <- utils::capture.output({
      .clauder_result <- withVisible(eval(parse(text = code), envir = work_env))
      if (.clauder_result$visible) print(.clauder_result$value)
    })

    if (length(output_names) > 0 && !is.null(outputs_path)) {
      collected <- mget(output_names, envir = work_env, ifnotfound = list(NULL))
      saveRDS(collected, outputs_path)
    }

    list(success = TRUE, output = paste(output_lines, collapse = "\n"))
  }, args = list(code = code, inputs_path = inputs_path, outputs_path = outputs_path,
                 output_names = output_names),
     supervise = TRUE, user_profile = FALSE)

  .claude_bg_jobs[[job_id]] <- list(
    process = job,
    started = Sys.time(),
    code = code,
    agent_id = agent_id,
    inputs_path = inputs_path,
    outputs_path = outputs_path,
    output_names = output_names
  )

  # Record submission in history (completion is tracked by the job itself)
  history_entry <- list(
    timestamp = Sys.time(),
    agent_id = if (!is.null(agent_id)) agent_id else "unknown",
    code = paste0("[async job ", job_id, " submitted] ", code),
    success = TRUE,
    has_plot = FALSE
  )
  .claude_history_env$entries <- c(.claude_history_env$entries, list(history_entry))

  list(success = TRUE, job_id = job_id)
}

#' Kill a running background job
#' @param job_id The job identifier to terminate
#' Sends SIGTERM (then SIGKILL after a brief grace period) via callr's kill().
#' Cleans up any inputs/outputs tempfiles. Safe to call on already-finished jobs.
kill_background_job <- function(job_id) {
  if (!exists(job_id, envir = .claude_bg_jobs)) {
    return(list(status = "not_found", success = FALSE,
                error = sprintf("No background job with id '%s'.", job_id)))
  }

  job_info <- .claude_bg_jobs[[job_id]]
  job <- job_info$process

  was_alive <- tryCatch(job$is_alive(), error = function(e) FALSE)
  elapsed <- as.numeric(difftime(Sys.time(), job_info$started, units = "secs"))

  if (was_alive) {
    tryCatch(job$kill(), error = function(e) NULL)
    tryCatch(job$kill_tree(), error = function(e) NULL)
  }

  # Cleanup marshaling tempfiles regardless of state.
  for (p in c(job_info$inputs_path, job_info$outputs_path)) {
    if (!is.null(p) && file.exists(p)) try(file.remove(p), silent = TRUE)
  }

  rm(list = job_id, envir = .claude_bg_jobs)

  list(
    status = "cancelled",
    success = TRUE,
    was_alive = was_alive,
    elapsed_seconds = round(elapsed)
  )
}

#' Check the status of a background job
#' @param job_id The job identifier to check
check_background_job <- function(job_id) {
  if (!exists(job_id, envir = .claude_bg_jobs)) {
    return(list(status = "not_found"))
  }

  job_info <- .claude_bg_jobs[[job_id]]

  # Already collected: replay the stored result. This makes polling
  # idempotent -- if the bridge timed out mid-collection, its retry still
  # gets the output instead of a spurious not_found.
  if (!is.null(job_info$final)) {
    return(job_info$final)
  }

  job <- job_info$process

  if (job$is_alive()) {
    elapsed <- as.numeric(difftime(Sys.time(), job_info$started, units = "secs"))
    return(list(status = "running", elapsed_seconds = round(elapsed)))
  }

  # Best-effort cleanup of marshaling tempfiles regardless of outcome.
  cleanup_files <- function() {
    for (p in c(job_info$inputs_path, job_info$outputs_path)) {
      if (!is.null(p) && file.exists(p)) try(file.remove(p), silent = TRUE)
    }
  }

  # Summarize a marshaled-back object for the agent (class + shape).
  summarize_obj <- function(name, obj) {
    cls <- paste(class(obj), collapse = "/")
    shape <- if (is.data.frame(obj)) sprintf("%d rows x %d cols", nrow(obj), ncol(obj))
             else if (is.matrix(obj)) sprintf("%d x %d", nrow(obj), ncol(obj))
             else if (is.atomic(obj) && !is.null(obj)) sprintf("length %d", length(obj))
             else if (is.list(obj)) sprintf("list with %d elements", length(obj))
             else "object"
    sprintf("  %s: %s [%s]", name, cls, shape)
  }

  # Job finished -- get result
  tryCatch({
    result <- job$get_result()

    # Marshal outputs back into the main session.
    marshaled_summary <- character(0)
    if (!is.null(job_info$outputs_path) && file.exists(job_info$outputs_path)) {
      outputs <- readRDS(job_info$outputs_path)
      for (nm in names(outputs)) {
        assign(nm, outputs[[nm]], envir = .GlobalEnv)
        marshaled_summary <- c(marshaled_summary, summarize_obj(nm, outputs[[nm]]))
      }
    }

    cleanup_files()

    out <- c(list(status = "complete"), result)
    if (length(marshaled_summary) > 0) {
      out$marshaled_outputs <- marshaled_summary
    }
    if (consensus_banner_needed() && !is.null(out$output)) {
      out$output <- paste0(out$output, "\n\n", CONSENSUS_BANNER)
    }
    # Keep the result (not the process) so later polls replay it
    .claude_bg_jobs[[job_id]] <- list(final = out, started = job_info$started)
    return(out)
  }, error = function(e) {
    # callr wraps errors -- dig out the original message
    err_msg <- if (!is.null(e$parent)) e$parent$message else e$message
    cleanup_files()
    out <- list(status = "complete", success = FALSE, error = err_msg)
    .claude_bg_jobs[[job_id]] <- list(final = out, started = job_info$started)
    return(out)
  })
}

#' Claude R Studio Add-in using HTTP server
#'
#' @importFrom shiny observeEvent reactiveValues renderText verbatimTextOutput
#'   actionButton numericInput checkboxInput textInput conditionalPanel
#'   showNotification invalidateLater runGadget paneViewer stopApp
#'   observe tags wellPanel
#' @importFrom miniUI gadgetTitleBar miniContentPanel miniPage
#' @importFrom httpuv startServer stopServer
#' @importFrom jsonlite fromJSON toJSON
#' @importFrom rstudioapi navigateToFile
#' @export

claudeAddin <- function() {
  # Restore viewer wrapper state (unwrap stale, will re-wrap on server start)
  unwrap_viewer()

  # Restore state from a still-running server (UI was closed but server kept going)
  resuming <- isTRUE(.claude_server_env$running) && !is.null(.claude_server_env$server)
  server_state <- if (resuming) .claude_server_env$server else NULL

  # Load settings. The canonical copy lives in .claude_server_env so the HTTP
  # handler and any reopened addin UI share one set of live values -- otherwise
  # a reopened UI would edit a fresh frame while the handler kept reading the
  # frame it closed over at server start, and toggles would silently stop
  # affecting the running server.
  settings <- load_claude_settings()
  if (resuming && !is.null(.claude_server_env$settings)) {
    settings <- .claude_server_env$settings
  }
  .claude_server_env$settings <- settings

  # Log file is created when the server starts (in the Start Server handler)
  # so we know the session name to include in the filename.

  # Start HTTP server function
  start_http_server <- function(port) {
    server <- startServer(
      host = "127.0.0.1",
      port = port,
      app = list(
        call = function(req) {
          # --- Auth gate ---
          # Binding to 127.0.0.1 is not a security boundary: any local process
          # can reach this port, and a webpage can POST to it cross-origin
          # without a CORS preflight (text/plain body). Both would land as
          # arbitrary R execution.
          #
          # Two independent defences, deliberately decoupled:
          #
          # 1. Origin block -- always on. Only browsers set Origin, and the MCP
          #    bridge never does, so this closes the drive-by-webpage vector at
          #    zero compatibility cost.
          # 2. Token check -- opt-in (settings$require_token). Enforcing it
          #    rejects any bridge older than clauder-mcp 0.6.0, so it stays off
          #    until the user has updated both halves. Turn it on in Advanced.
          if (!is.null(req$HTTP_ORIGIN)) {
            return(list(
              status = 403L,
              headers = list('Content-Type' = 'application/json'),
              body = '{"error": "Forbidden: browser-originated requests are not accepted"}'
            ))
          }

          expected_token <- .claude_server_env$token
          supplied_token <- req$HTTP_X_CLAUDER_TOKEN

          if (isTRUE(.claude_server_env$require_token)) {
            if (is.null(expected_token) || !identical(supplied_token, expected_token)) {
              return(list(
                status = 401L,
                headers = list('Content-Type' = 'application/json'),
                body = '{"error": "Unauthorized: missing or invalid X-Clauder-Token. Your clauder-mcp bridge is older than 0.6.0 -- run `uvx --refresh clauder-mcp`, or untick Require token in the addin Advanced panel."}'
              ))
            }
          } else if (is.null(supplied_token) && !isTRUE(.claude_server_env$warned_no_token)) {
            .claude_server_env$warned_no_token <- TRUE
            message(
              "[ClaudeR] Bridge connected without an auth token (clauder-mcp < 0.6.0). ",
              "Any local process can reach this port. After updating the bridge, ",
              "tick 'Require token' in the addin's Advanced panel to lock it down."
            )
          }

          # Handle POST requests (receiving code from Claude)
          if (req$REQUEST_METHOD == "POST") {
            # Parse the request body
            body_raw <- req$rook.input$read()
            body <- tryCatch(fromJSON(rawToChar(body_raw)), error = function(e) NULL)
            if (is.null(body)) {
              return(list(
                status = 400L,
                headers = list('Content-Type' = 'application/json'),
                body = '{"error": "Invalid JSON in request body"}'
              ))
            }

            # --- Check background job status ---
            if (!is.null(body$check_job)) {
              result <- check_background_job(body$check_job)
              response_body <- toJSON(result, auto_unbox = TRUE, force = TRUE)
              return(list(
                status = 200L,
                headers = list('Content-Type' = 'application/json'),
                body = response_body
              ))
            }

            # --- Cancel a running background job ---
            if (!is.null(body$cancel_job)) {
              result <- kill_background_job(body$cancel_job)
              response_body <- toJSON(result, auto_unbox = TRUE, force = TRUE)
              return(list(
                status = 200L,
                headers = list('Content-Type' = 'application/json'),
                body = response_body
              ))
            }

            # --- Get viewer content (paginated) ---
            if (!is.null(body$get_viewer)) {
              max_length <- if (!is.null(body$max_length)) as.integer(body$max_length) else 10000L
              offset <- if (!is.null(body$offset)) as.integer(body$offset) else 0L

              last_url <- .claude_viewer_env$last_url
              if (is.null(last_url) || !file.exists(last_url)) {
                result <- list(success = FALSE, error = "No viewer content available.")
              } else {
                html <- paste(readLines(last_url, warn = FALSE), collapse = "\n")
                total <- nchar(html)
                start_pos <- offset + 1L
                end_pos <- min(offset + max_length, total)
                chunk <- if (start_pos > total) "" else substr(html, start_pos, end_pos)
                result <- list(success = TRUE, content = chunk,
                               total_chars = total, offset = offset,
                               returned_chars = nchar(chunk))
              }
              response_body <- toJSON(result, auto_unbox = TRUE, force = TRUE)
              return(list(
                status = 200L,
                headers = list('Content-Type' = 'application/json'),
                body = response_body
              ))
            }

            if (!is.null(body$code)) {
              agent_id <- body$agent_id  # NULL if not provided (backwards compatible)

              # --- Async: launch in background via callr ---
              if (isTRUE(body$async) && !is.null(body$job_id)) {
                input_names  <- if (!is.null(body$input_names))  as.character(body$input_names)  else character(0)
                output_names <- if (!is.null(body$output_names)) as.character(body$output_names) else character(0)
                result <- start_background_job(
                  body$code, body$job_id, .claude_server_env$settings,
                  agent_id = agent_id,
                  input_names = input_names,
                  output_names = output_names
                )
                .claude_server_env$execution_count <- .claude_server_env$execution_count + 1L
                response_body <- toJSON(result, auto_unbox = TRUE, force = TRUE)
                return(list(
                  status = 200L,
                  headers = list('Content-Type' = 'application/json'),
                  body = response_body
                ))
              }

              # --- Sync: execute in main session ---
              result <- execute_code_in_session(body$code, .claude_server_env$settings, agent_id = agent_id)
              .claude_server_env$execution_count <- .claude_server_env$execution_count + 1L

              # Return the result as JSON
              response_body <- toJSON(result, auto_unbox = TRUE, force = TRUE)

              return(list(
                status = 200L,
                headers = list('Content-Type' = 'application/json'),
                body = response_body
              ))
            }

            return(list(
              status = 400L,
              headers = list('Content-Type' = 'application/json'),
              body = '{"error": "Missing code or check_job parameter"}'
            ))
          }

          # Handle GET requests (status checks)
          if (req$REQUEST_METHOD == "GET") {
            agent_ids <- unique(vapply(
              .claude_history_env$entries,
              function(e) e$agent_id, character(1)
            ))
            live <- .claude_server_env$settings
            status <- list(
              running = isTRUE(.claude_server_env$running),
              execution_count = .claude_server_env$execution_count,
              # as.list() keeps this a JSON array even with one element;
              # auto_unbox would collapse it to a bare string, which the
              # bridge then iterates character by character
              connected_agents = as.list(agent_ids),
              history_size = length(.claude_history_env$entries),
              session_name = .claude_server_env$session_name,
              log_file_path = if (isTRUE(live$log_to_file)) live$log_file_path else NULL
            )

            return(list(
              status = 200L,
              headers = list('Content-Type' = 'application/json'),
              body = toJSON(status, auto_unbox = TRUE)
            ))
          }

          # Default response for other request types
          return(list(
            status = 405L,
            headers = list('Content-Type' = 'application/json'),
            body = '{"error": "Method not allowed"}'
          ))
        }
      )
    )
    return(server)
  }

  # UI definition
  ui <- miniPage(
    gadgetTitleBar("Claude R Connection"),
    miniContentPanel(
      tags$style("
        .section-label { font-weight: 600; font-size: 13px; margin-bottom: 8px; color: #555; }
        .well { padding: 12px; margin-bottom: 10px; }
        .status-text { font-family: monospace; font-size: 12px; margin: 4px 0; }
        .btn { margin-right: 4px; }
      "),

      # --- Session ---
      tags$div(class = "section-label",
        "SESSION",
        actionButton("session_help", "?",
          class = "btn-default btn-xs",
          style = "margin-left: 6px; padding: 1px 6px; font-size: 11px; vertical-align: middle;"
        )
      ),
      wellPanel(
        textInput("session_name", "Session Name",
          value = if (resuming && !is.null(.claude_server_env$session_name)) .claude_server_env$session_name else "default"),
        numericInput("port", "Port",
          value = if (resuming && !is.null(.claude_server_env$port)) .claude_server_env$port else 8787,
          min = 1024, max = 65535),
        verbatimTextOutput("serverStatus"),
        actionButton("startServer", "Start Server", class = "btn-primary btn-sm"),
        actionButton("stopServer", "Stop Server", class = "btn-danger btn-sm"),
        tags$div(style = "display: flex; align-items: center; gap: 6px;",
          checkboxInput("fresh_start", "Fresh start on restart", value = FALSE),
          actionButton("fresh_start_help", "?",
            class = "btn-default btn-xs",
            style = "padding: 1px 6px; font-size: 11px; margin-top: -15px;"
          )
        )
      ),

      # --- Agents ---
      tags$div(class = "section-label",
        "AGENTS",
        actionButton("agents_help", "?",
          class = "btn-default btn-xs",
          style = "margin-left: 6px; padding: 1px 6px; font-size: 11px; vertical-align: middle;"
        )
      ),
      wellPanel(
        verbatimTextOutput("agentInfo")
      ),

      # --- Logging ---
      tags$div(class = "section-label", "LOGGING"),
      wellPanel(
        checkboxInput("print_to_console", "Print code to console before execution",
                             value = settings$print_to_console),
        checkboxInput("log_to_file", "Log code to file",
                             value = settings$log_to_file),
        conditionalPanel(
          condition = "input.log_to_file == true",
          textInput("log_file_path", "Log file path",
                           value = settings$log_file_path),
          checkboxInput("log_console", "Also log my own console commands",
                           value = isTRUE(settings$log_console)),
          actionButton("open_log", "Open Log File", class = "btn-sm"),
          actionButton("export_script", "Export Clean Script", class = "btn-sm")
        )
      ),

      # --- Advanced ---
      tags$div(class = "section-label",
        "ADVANCED",
        actionButton("advanced_help", "?",
          class = "btn-default btn-xs",
          style = "margin-left: 6px; padding: 1px 6px; font-size: 11px; vertical-align: middle;"
        )
      ),
      wellPanel(
        actionButton("kill_process", "Force Release Port", class = "btn-warning btn-sm"),
        tags$hr(style = "margin: 10px 0;"),
        checkboxInput("require_token",
          "Require auth token (needs clauder-mcp >= 0.6.0)",
          value = isTRUE(settings$require_token)
        ),
        tags$div(
          style = "font-size: 11px; color: #777; margin-top: -8px;",
          "Rejects any request without this session's token. Update your bridge",
          tags$code("uvx --refresh clauder-mcp"),
          "before enabling, then restart the server."
        )
      )
    )
  )

  # Server function
  server <- function(input, output, session) {
    # State management
    state <- reactiveValues(
      running = resuming,
      execution_count = .claude_server_env$execution_count
    )

    # If resuming, re-wrap viewer since we unwrapped at startup
    if (resuming) {
      wrap_viewer()
    }

    # Update settings reactively (ignoreInit prevents overwriting on UI load).
    # Writes go to the canonical copy in .claude_server_env so the HTTP
    # handler sees them even after the UI was closed and reopened.
    update_setting <- function(name, value) {
      s <- .claude_server_env$settings
      s[[name]] <- value
      .claude_server_env$settings <- s
      settings <<- s
      save_claude_settings(s)
    }
    observeEvent(input$print_to_console, {
      update_setting("print_to_console", input$print_to_console)
    }, ignoreInit = TRUE)
    observeEvent(input$log_console, {
      update_setting("log_console", input$log_console)
      if (isTRUE(input$log_console)) start_console_logging() else stop_console_logging()
    }, ignoreInit = TRUE)

    observeEvent(input$log_to_file, {
      update_setting("log_to_file", input$log_to_file)
    }, ignoreInit = TRUE)
    observeEvent(input$log_file_path, {
      update_setting("log_file_path", input$log_file_path)
    }, ignoreInit = TRUE)
    observeEvent(input$require_token, {
      update_setting("require_token", input$require_token)
      if (isTRUE(state$running)) {
        showNotification("Restart the server for the token setting to take effect.",
                         type = "warning")
      }
    }, ignoreInit = TRUE)

    # Open log file button
    observeEvent(input$open_log, {
      if (file.exists(input$log_file_path)) {
        if (requireNamespace("rstudioapi", quietly = TRUE)) {
          navigateToFile(input$log_file_path)
        } else {
          file.show(input$log_file_path)
        }
      } else {
        showNotification("Log file does not exist yet.", type = "warning")
      }
    })

    # Export clean script button
    observeEvent(input$export_script, {
      if (file.exists(input$log_file_path)) {
        tryCatch({
          out <- export_log_as_script(input$log_file_path)
          showNotification(paste("Exported to:", basename(out)), type = "message")
          if (requireNamespace("rstudioapi", quietly = TRUE)) {
            navigateToFile(out)
          }
        }, error = function(e) {
          showNotification(paste("Export failed:", e$message), type = "error")
        })
      } else {
        showNotification("Log file does not exist yet.", type = "warning")
      }
    })

    # Server status output
    output$serverStatus <- renderText({
      invalidateLater(2000)
      if (state$running) {
        sprintf("Running on http://127.0.0.1:%d", input$port)
      } else {
        "Not running"
      }
    })

    # Agent info output
    output$agentInfo <- renderText({
      invalidateLater(2000)
      entries <- .claude_history_env$entries
      agent_ids <- unique(vapply(entries, function(e) e$agent_id, character(1)))
      n_agents <- length(agent_ids)
      n_exec <- length(entries)

      exec_txt <- if (n_agents == 0) {
        "No code executed by agents yet"
      } else {
        sprintf("Executed code: %s\nExecutions: %d",
                paste(agent_ids, collapse = ", "), n_exec)
      }

      # Coordination happens on disk without touching R, so agents that only
      # message each other never appear in the execution history. Surface
      # them from the event log so the human can see who is actually around.
      roster <- if (isTRUE(.claude_server_env$running)) {
        coord_roster_text(.claude_server_env$session_name)
      } else NULL
      if (!is.null(roster)) {
        paste0(exec_txt, "\nCoordinating: ", roster)
      } else {
        exec_txt
      }
    })

    # Session help popup
    observeEvent(input$session_help, {
      shiny::showModal(shiny::modalDialog(
        title = "Multi-Session & Agent Guide",
        tags$div(
          tags$h5("Single Session (Default)"),
          tags$p("Just click Start Server. AI agents will auto-discover your session."),

          tags$h5("Multiple Sessions"),
          tags$p("To run separate RStudio windows with different AI agents:"),
          tags$ol(
            tags$li(tags$b("Window 1:"), " Set Session Name to e.g. 'analysis', keep port 8787, click Start."),
            tags$li(tags$b("Window 2:"), " Set Session Name to e.g. 'modeling', change port to 8788, click Start."),
            tags$li("Each agent auto-connects to the first available session. To assign an agent to a specific session, tell it: ",
              tags$em("\"Connect to the 'modeling' session using connect_session.\""))
          ),

          tags$h5("Agent Identity"),
          tags$p("Each AI agent is assigned a unique ID (e.g. agent-a3f92b1c) on startup.",
            "All code it executes is logged under that ID.",
            "If you see multiple agent IDs in the Agents panel, multiple AI tools are sharing this R session."),

          tags$h5("Checking Agent Activity"),
          tags$p("Agents can call ", tags$code("get_session_history"),
            " to see what other agents have done.",
            "If logging is enabled, the log file also shows which agent executed each block of code.")
        ),
        easyClose = TRUE,
        footer = shiny::modalButton("Got it")
      ))
    })

    # Fresh start help popup
    observeEvent(input$fresh_start_help, {
      shiny::showModal(shiny::modalDialog(
        title = "Fresh Start",
        tags$div(
          tags$p("Check this box before clicking ", tags$b("Start Server"), " to reset the session to a clean state."),
          tags$p("What gets reset:"),
          tags$ul(
            tags$li(tags$b("Log file"), " - a new timestamped log is created with a fresh sessionInfo() header."),
            tags$li(tags$b("Agent history"), " - the execution history is cleared. get_session_history returns empty."),
            tags$li(tags$b("Execution count"), " - resets to 0."),
            tags$li(tags$b("Console history"), " - clears the R console command history.")
          ),
          tags$p("Your R environment (variables, loaded packages) is ", tags$b("not"), " cleared.",
            "To also clear the environment, run ", tags$code("rm(list = ls())"), " before restarting.")
        ),
        easyClose = TRUE,
        footer = shiny::modalButton("Got it")
      ))
    })

    # Advanced help popup
    observeEvent(input$advanced_help, {
      shiny::showModal(shiny::modalDialog(
        title = "Advanced",
        tags$div(
          tags$p(tags$b("Force Release Port"), " is a last-resort option for when ",
            tags$b("Stop Server"), " fails to free the port."),
          tags$p("What it does:"),
          tags$ul(
            tags$li("Finds whatever process is holding the port using ", tags$code("lsof"), "."),
            tags$li("Force-kills that process with ", tags$code("kill -9"), "."),
            tags$li("Clears all server state so you can start fresh.")
          ),
          tags$p(tags$b("When to use it:"), " Only if you see an 'address already in use' error ",
            "and Stop Server doesn't fix it (e.g., a zombie process from a crashed session is squatting on the port).")
        ),
        easyClose = TRUE,
        footer = shiny::modalButton("Got it")
      ))
    })

    # Agents help popup
    observeEvent(input$agents_help, {
      shiny::showModal(shiny::modalDialog(
        title = "Agents Panel",
        tags$div(
          tags$p("This panel shows AI agents that have executed code in the current session."),
          tags$h5("What you'll see"),
          tags$ul(
            tags$li(tags$b("Connected:"), " lists the unique agent IDs (e.g. agent-a3f92b1c) that have run code this session."),
            tags$li(tags$b("Executions:"), " total number of code blocks executed across all agents.")
          ),
          tags$h5("How it works"),
          tags$p("Each AI tool (Claude Code, Codex, Gemini, etc.) is assigned a unique agent ID when it first connects.",
            "If you see multiple IDs, multiple agents are sharing this R session.",
            "They can see each other's work through ", tags$code("get_session_history"), " and the shared log file."),
          tags$p("Use ", tags$b("Fresh start on restart"), " to clear agent history when starting a new task.")
        ),
        easyClose = TRUE,
        footer = shiny::modalButton("Got it")
      ))
    })

    # Start server
    observeEvent(input$startServer, {
      if (!state$running) {
        tryCatch({
          # Clean up any stale discovery files from crashed sessions
          cleanup_stale_discovery_files()

          # Fresh start: also reset agent history, execution count, console history
          if (isTRUE(input$fresh_start)) {
            .claude_server_env$execution_count <- 0L
            state$execution_count <- 0
            .claude_history_env$entries <- list()

            # Clear R console history
            tryCatch({
              tmp_hist <- tempfile()
              writeLines("", tmp_hist)
              utils::loadhistory(tmp_hist)
              unlink(tmp_hist)
            }, error = function(e) NULL)  # silently skip if not supported

            showNotification("Fresh start: log, history, and agents reset", type = "message")
          }

          # Mint the session token before the server starts accepting requests.
          .claude_server_env$token <- generate_session_token()
          .claude_server_env$require_token <- isTRUE(input$require_token)
          .claude_server_env$warned_no_token <- FALSE

          server_state <<- start_http_server(input$port)

          # Persist resume state immediately: if anything below fails, the
          # server is already listening and must stay resumable/stoppable.
          .claude_server_env$server <- server_state
          .claude_server_env$running <- TRUE
          .claude_server_env$port <- input$port
          state$running <- TRUE

          # Resolve session name
          session_name <- trimws(input$session_name)
          if (session_name == "") session_name <- paste0("session_", input$port)
          .claude_server_env$session_name <- session_name
          .claude_server_env$coord_seen <- NULL  # re-baseline coordination echo
          write_discovery_file(session_name, input$port, .claude_server_env$token)

          # Create log file with session name in the filename
          if (isTRUE(.claude_server_env$settings$log_to_file)) {
            session_timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
            safe_name <- gsub("[^a-zA-Z0-9_-]", "_", session_name)
            new_log <- file.path(
              dirname(.claude_server_env$settings$log_file_path),
              paste0("clauder_", safe_name, "_", input$port, "_", session_timestamp, ".R")
            )
            update_setting("log_file_path", new_log)
            write_log_header(new_log)
            shiny::updateTextInput(session, "log_file_path", value = new_log)
          }

          # Wrap viewer to capture HTML widget URLs
          wrap_viewer()

          showNotification("HTTP server started successfully", type = "message")
        }, error = function(e) {
          message("Error starting HTTP server: ", e$message)
          showNotification(
            paste("Failed to start HTTP server:", e$message),
            type = "error"
          )
        })
      }
    })

    # Stop server
    observeEvent(input$stopServer, {
      if (state$running) {
        tryCatch({
          stopServer(server_state)
          state$running <- FALSE
          server_state <<- NULL

          # Remove discovery file before clearing the session name
          if (!is.null(.claude_server_env$session_name)) {
            remove_discovery_file(.claude_server_env$session_name)
          }

          # Clear persisted state
          .claude_server_env$server <- NULL
          .claude_server_env$running <- FALSE
          .claude_server_env$port <- NULL
          .claude_server_env$session_name <- NULL
          .claude_server_env$execution_count <- 0L
          .claude_server_env$token <- NULL

          # Reset execution count and agent history
          state$execution_count <- 0
          .claude_history_env$entries <- list()

          # Restore original viewer
          unwrap_viewer()

          # Don't leave graphics functions traced in the user's session
          remove_draw_tracers()

          # Force garbage collection to ensure port is released
          gc()

          showNotification("HTTP server stopped", type = "message")
        }, error = function(e) {
          message("Error stopping server: ", e$message)
          showNotification("Failed to stop server cleanly", type = "error")
        })
      }
    })

    
    # Force release port button handler
    shiny::observeEvent(input$kill_process, {
      if (.Platform$OS.type == "windows") {
        shiny::showNotification(
          "Force Release Port uses lsof/kill and is not available on Windows. Restart the R session instead.",
          type = "warning"
        )
        return(invisible(NULL))
      }
      # Create a confirmation dialog
      shiny::showModal(shiny::modalDialog(
        title = "Force Release Port",
        "This will force-kill whatever process is holding the port. Your R environment and variables will not be affected.",
        footer = shiny::tagList(
          shiny::modalButton("Cancel"),
          shiny::actionButton("confirm_kill", "Continue", class = "btn-danger")
        ),
        easyClose = FALSE
      ))
    })
    
    # Handle confirmation of process kill
    shiny::observeEvent(input$confirm_kill, {
      # Close the modal dialog
      shiny::removeModal()
      
      # Proceed with killing the process
      tryCatch({
        # Run system command to find the process using port 8787
        port_to_kill <- input$port
        cmd_result <- system(paste0("lsof -i :", port_to_kill, " | grep LISTEN"), intern = TRUE)
        
        if (length(cmd_result) > 0) {
          # Extract PID from the result (typically the second column)
          pid <- strsplit(cmd_result, "\\s+")[[1]][2]
          
          if (!is.na(pid) && pid != "") {
            # Kill the process
            kill_result <- system(paste0("kill -9 ", pid), intern = TRUE)
            shiny::showNotification(paste0("Process ", pid, " using port ", port_to_kill, " terminated."), type = "message")
            
            # Reset server state
            if (!is.null(server_state)) {
              try(httpuv::stopServer(server_state), silent = TRUE)
              server_state <<- NULL
            }
            # Remove discovery file before clearing the session name
            if (!is.null(.claude_server_env$session_name)) {
              remove_discovery_file(.claude_server_env$session_name)
            }

            .claude_server_env$server <- NULL
            .claude_server_env$running <- FALSE
            .claude_server_env$port <- NULL
            .claude_server_env$session_name <- NULL
            .claude_server_env$execution_count <- 0L
            .claude_server_env$token <- NULL
            state$running <- FALSE

            # Restore the viewer and untrace graphics functions -- this path
            # bypasses Stop Server, which normally does this cleanup
            unwrap_viewer()
            remove_draw_tracers()

            # Force garbage collection
            gc()
          } else {
            shiny::showNotification("Could not identify process ID.", type = "warning")
          }
        } else {
          shiny::showNotification(paste0("No process found using port ", port_to_kill), type = "warning")
        }
      }, error = function(e) {
        shiny::showNotification(paste0("Error killing process: ", e$message), type = "error")
      })
    })
    # Refresh the execution count shown in the UI from the canonical state
    observe({
      state$execution_count <- .claude_server_env$execution_count
      invalidateLater(2000)
    })

    # Echo coordination traffic to the console and session log. Coordination
    # bypasses the R server by design (a busy session cannot block it), so
    # without this the human sees none of it.
    observe({
      invalidateLater(2000)
      if (!isTRUE(.claude_server_env$running)) return(invisible(NULL))
      evs <- tryCatch(coord_events(.claude_server_env$session_name),
                      error = function(e) list())
      if (length(evs) == 0) return(invisible(NULL))
      max_id <- max(vapply(evs, function(e) e$id, integer(1)))
      seen <- .claude_server_env$coord_seen
      if (is.null(seen)) {
        # First look at this log: do not replay history into the console
        .claude_server_env$coord_seen <- max_id
        return(invisible(NULL))
      }
      new_evs <- Filter(function(e) e$id > seen, evs)
      if (length(new_evs) == 0) return(invisible(NULL))
      s <- .claude_server_env$settings
      for (e in new_evs) {
        line <- tryCatch(format_coord_event(e), error = function(err) NULL)
        if (is.null(line)) next
        if (isTRUE(s$print_to_console)) {
          cat("### coordination ###", line, "\n")
        }
        if (isTRUE(s$log_to_file) && !is.null(s$log_file_path) &&
            nzchar(s$log_file_path)) {
          try(cat(sprintf("# [coordination] %s\n", line),
                  file = s$log_file_path, append = TRUE), silent = TRUE)
        }
      }
      .claude_server_env$coord_seen <- max_id
    })

    # Close handler -- just close the UI, keep the server running
    observeEvent(input$done, {
      invisible(stopApp())
    })
  }

  runGadget(ui, server, viewer = paneViewer())
}

#' Summarize a result value for transport back to the agent
#'
#' `output` already carries the printed representation of the value, so
#' serializing the object itself is only useful when it is small. Anything
#' larger gets a shape summary instead -- otherwise a visible `1:1e6` would
#' ship a million numbers as JSON on top of the printed output that already
#' describes them.
#'
#' @param value The value returned by the evaluated code
#' @param max_len Longest atomic vector to serialize verbatim
#' @return A JSON-serializable summary of `value`
summarize_result_value <- function(value, max_len = 100L) {
  if (is.data.frame(value)) {
    return(list(
      is_dataframe = TRUE,
      dimensions = dim(value),
      head = utils::head(value, 10)
    ))
  }
  if (inherits(value, "ggplot")) {
    return("ggplot object - see plot output")
  }
  if (is.atomic(value) && length(value) <= max_len && is.null(dim(value))) {
    return(value)
  }

  summary <- list(
    truncated = TRUE,
    class = paste(class(value), collapse = "/"),
    length = length(value),
    note = "Object too large to serialize. See the printed output above."
  )
  if (!is.null(dim(value))) summary$dimensions <- dim(value)
  summary
}

#' Cap captured console output before sending it to the agent
#'
#' A visible large object prints its entire contents to stdout, so uncapped
#' output is the larger of the two payload bombs (`summarize_result_value`
#' handles the other). Keeps the head and the tail: the head shows what the
#' object looks like, and the tail preserves the warnings and messages, which
#' are appended last and matter most.
#'
#' @param lines Character vector of captured output lines
#' @param max_lines Maximum lines to keep
#' @param max_chars Hard character ceiling applied after line trimming
#' @return A single truncated string
truncate_output <- function(lines, max_lines = 500L, max_chars = 50000L) {
  if (length(lines) > max_lines) {
    head_n <- as.integer(max_lines * 0.8)
    tail_n <- max_lines - head_n
    lines <- c(
      utils::head(lines, head_n),
      sprintf("... [%d lines omitted] ...", length(lines) - max_lines),
      utils::tail(lines, tail_n)
    )
  }
  txt <- paste(lines, collapse = "\n")
  if (nchar(txt) > max_chars) {
    txt <- paste0(
      substr(txt, 1L, max_chars),
      sprintf("\n... [output truncated at %d characters]", max_chars)
    )
  }
  txt
}

#' Execute R code in the active RStudio session
#'
#' This function executes the provided R code in the global environment
#' and captures both the result and any output.
#'
#' @param code The R code to execute
#' @param settings The settings list with logging preferences
#' @param agent_id Optional agent identifier for attribution
#' @return A list containing the execution result and metadata
#' @importFrom ggplot2 ggplot aes geom_bar geom_line theme_minimal ggsave
#' @importFrom base64enc base64encode
#' @importFrom grDevices dev.copy dev.list dev.off png jpeg recordPlot
#' @export

execute_code_in_session <- function(code, settings = NULL, agent_id = NULL) {
  # Default settings if not provided
  if (is.null(settings)) {
    settings <- load_claude_settings()
  }

  # Validate the code to block dangerous operations
  validation_result <- validate_code_security(code)
  if (validation_result$blocked) {
    return(list(
      success = FALSE,
      error = validation_result$reason
    ))
  }

  # Print code to console if enabled
  if (settings$print_to_console) {
    agent_label <- if (!is.null(agent_id)) paste0(" [", agent_id, "]") else ""
    cat(sprintf("\n### LLM%s executing the following code ###\n", agent_label))
    cat(code, "\n")
    cat("### End of LLM code ###\n\n")
  }

  # Log code to file if enabled
  if (settings$log_to_file && !is.null(settings$log_file_path) && settings$log_file_path != "") {
    log_code_to_file(code, settings$log_file_path, agent_id = agent_id)
  }

  # Create a temporary environment for evaluation
  env <- .GlobalEnv

  # Set up plot capture files (PNG primary, JPEG fallback)
  plot_file_png <- tempfile(fileext = ".png")
  plot_file_jpeg <- tempfile(fileext = ".jpeg")

  tryCatch({
    # Arm draw detection before sink() opens, so trace()'s own one-time
    # "Tracing function ..." chatter cannot land in the agent's output.
    tracers <- install_draw_tracers()
    tracing_active <- length(tracers) > 0
    .claude_plot_env$drew <- FALSE
    .claude_plot_env$devs <- integer(0)

    # Create a connection to capture output. Remember the sink depth so
    # cleanup unwinds exactly the sinks opened during this execution, even
    # if the executed code called sink() itself and then errored.
    output_file <- tempfile()
    sink_depth <- sink.number()
    sink(output_file, split = TRUE)  # split=TRUE sends output to console AND capture

    # --- BEFORE eval: snapshot device state to detect stale plots ---
    devices_before <- dev.list()
    # Only needed for the no-tracing fallback below. When tracing is active this
    # deep-copy of the display list -- previously paid on every call, graphics or
    # not -- is skipped entirely.
    baseline_plot <- if (!tracing_active && !is.null(devices_before)) {
      tryCatch(recordPlot(), error = function(e) NULL)
    } else NULL

    # Suppress viewer during agent execution so htmlwidgets don't steal the pane
    # Reset last_url so viewer_captured only flags for THIS execution
    .claude_viewer_env$last_url <- NULL
    .claude_viewer_env$suppress <- TRUE
    on.exit(.claude_viewer_env$suppress <- FALSE, add = TRUE)

    # Expose the executing agent's identity to coordination functions
    # (cr_send, confirm_agreement, ...) so attribution needs no arguments.
    old_agent_env <- Sys.getenv("CLAUDER_AGENT_ID", "")
    if (!is.null(agent_id) && nzchar(agent_id)) {
      Sys.setenv(CLAUDER_AGENT_ID = agent_id)
    }
    on.exit({
      if (nzchar(old_agent_env)) Sys.setenv(CLAUDER_AGENT_ID = old_agent_env)
      else Sys.unsetenv("CLAUDER_AGENT_ID")
    }, add = TRUE)

    # sink() only diverts stdout. Warnings and message() go to stderr, so
    # without this the agent never sees them -- including the ones that matter
    # most (non-convergence, singular fits, NAs introduced by coercion).
    # Handlers do not muffle: the conditions still reach the console as usual.
    collected_conditions <- character(0)

    # Execute code in the global environment
    result <- withCallingHandlers(
      withVisible(eval(parse(text = code), envir = env)),
      warning = function(w) {
        collected_conditions <<- c(collected_conditions,
                                   paste0("Warning: ", conditionMessage(w)))
      },
      message = function(m) {
        collected_conditions <<- c(collected_conditions,
                                   paste0("Message: ", sub("\n$", "", conditionMessage(m))))
      }
    )

    # Print the result if it would be auto-printed in console
    if (result$visible) {
      print(result$value)
    }

    # Stop capturing output
    sink()

    # Read the captured output
    output <- readLines(output_file, warn = FALSE)
    if (length(collected_conditions) > 0) {
      output <- c(output, collected_conditions)
    }

    # This execution's sink was opened on top of the console-logging sink (if
    # one is active), and split = TRUE cascades, so everything printed here has
    # also landed in the console buffer. Drop it, or the next thing the user
    # types would carry the agent's output as if the user had produced it.
    tryCatch(console_drain(), error = function(e) NULL)

    # Record what the code printed, not just the code. The log is the one file
    # an agent reads back to see what happened, and until now it showed the
    # call but never its result.
    if (settings$log_to_file && !is.null(settings$log_file_path) &&
        settings$log_file_path != "" && length(output) > 0) {
      tryCatch(log_output_to_file(output, settings$log_file_path),
               error = function(e) NULL)
    }

    # --- AFTER eval: only capture if a NEW plot was actually created ---
    captured_plot <- FALSE
    plot_data <- NULL
    plot_mime <- "image/png"

    tryCatch({
      # For ggplot objects: always a new plot
      if (inherits(result$value, "ggplot")) {
        # Try PNG first (sharp lines/text, often smaller for plots)
        tryCatch({
          ggsave(plot_file_png, result$value,
                 device = "png", width = 6, height = 4, dpi = 100)
          if (file.exists(plot_file_png) && file.info(plot_file_png)$size > 100) {
            plot_data <- base64encode(plot_file_png)
            plot_mime <- "image/png"
            captured_plot <- TRUE
          }
        }, error = function(e) {
          # JPEG fallback for ggplot
          message("PNG ggsave failed, trying JPEG: ", e$message)
          tryCatch({
            ggsave(plot_file_jpeg, result$value,
                   device = "jpeg", width = 6, height = 4,
                   dpi = 100, quality = 80)
            if (file.exists(plot_file_jpeg) && file.info(plot_file_jpeg)$size > 100) {
              plot_data <<- base64encode(plot_file_jpeg)
              plot_mime <<- "image/jpeg"
              captured_plot <<- TRUE
            }
          }, error = function(e2) {
            message("JPEG ggsave fallback also failed: ", e2$message)
          })
        })
      }
      # For base graphics: only capture if this execution actually drew something
      else if (!is.null(dev.list())) {
        devices_after <- dev.list()

        # A traced draw event is authoritative: it fires on a redraw of an
        # identical figure, which the old display-list comparison reported as
        # stale (and so never sent to the agent). It only counts if the draw
        # landed on the *current, screen* device -- `png(f); plot(x); dev.off()`
        # fires the tracer too, and capturing then would resend the old figure
        # still sitting on the screen device.
        if (tracing_active) {
          new_plot_exists <- isTRUE(.claude_plot_env$drew) &&
            (grDevices::dev.cur() %in% .claude_plot_env$devs) &&
            is_screen_device()
        } else {
          new_plot_exists <- !identical(devices_before, devices_after)
        }

        # Fallback only if tracing could not be installed -- better to pay for
        # the old comparison than to silently drop plots.
        if (!new_plot_exists && !tracing_active) {
          current_plot <- tryCatch(recordPlot(), error = function(e) NULL)
          new_plot_exists <- !is.null(current_plot) &&
            !identical(current_plot, baseline_plot)
        }

        if (new_plot_exists) {
          # Try PNG first (sharp lines/text, often smaller for plots)
          tryCatch({
            dev.copy(png, filename = plot_file_png,
                     width = 600, height = 400)
            dev.off()
            if (file.exists(plot_file_png) && file.info(plot_file_png)$size > 100) {
              plot_data <- base64encode(plot_file_png)
              plot_mime <- "image/png"
              captured_plot <- TRUE
            }
          }, error = function(e) {
            # JPEG fallback for base graphics
            message("PNG dev.copy failed, trying JPEG: ", e$message)
            tryCatch({
              dev.copy(jpeg, filename = plot_file_jpeg,
                       width = 600, height = 400, quality = 80)
              dev.off()
              if (file.exists(plot_file_jpeg) && file.info(plot_file_jpeg)$size > 100) {
                plot_data <<- base64encode(plot_file_jpeg)
                plot_mime <<- "image/jpeg"
                captured_plot <<- TRUE
              }
            }, error = function(e2) {
              message("JPEG fallback also failed: ", e2$message)
            })
          })
        }
      }
    }, error = function(e) {
      message("Note: Could not capture plot: ", e$message)
    })

    # Prepare the response
    response <- list(
      success = TRUE,
      output = truncate_output(output)
    )

    # Consensus gate: while a proposed plan lacks the required verbatim
    # confirmations, every response carries the banner. Deliberately loud.
    if (consensus_banner_needed()) {
      response$output <- paste0(response$output, "\n\n", CONSENSUS_BANNER)
    }

    # Include the result value if available
    if (exists("result") && !is.null(result$value)) {
      response$result <- summarize_result_value(result$value)
    }

    # Include plot if available
    if (captured_plot && !is.null(plot_data)) {
      response$plot <- list(
        data = plot_data,
        mime_type = plot_mime
      )
    }

    # Flag if viewer content was captured (htmlwidgets)
    if (!is.null(.claude_viewer_env$last_url) &&
        file.exists(.claude_viewer_env$last_url)) {
      response$viewer_captured <- TRUE
    }

    # Record to agent history
    history_entry <- list(
      timestamp = Sys.time(),
      agent_id = if (!is.null(agent_id)) agent_id else "unknown",
      code = code,
      success = TRUE,
      has_plot = captured_plot
    )
    .claude_history_env$entries <- c(.claude_history_env$entries, list(history_entry))
    if (length(.claude_history_env$entries) > .claude_history_env$max_entries) {
      .claude_history_env$entries <- utils::tail(.claude_history_env$entries, .claude_history_env$max_entries)
    }

    return(response)
  }, error = function(e) {
    # Unwind any sinks opened during this execution
    if (exists("sink_depth")) {
      while (sink.number() > sink_depth) sink()
    }
    # No sink_depth means we failed before opening one. Do NOT pop blindly:
    # console logging keeps a sink of its own underneath, and popping it
    # silently stops the user's console from being recorded.

    # Recover whatever was printed before the error: partial output plus
    # captured warnings/messages are often exactly the context the agent
    # needs to fix the code
    partial_output <- character(0)
    if (exists("output_file") && file.exists(output_file)) {
      partial_output <- tryCatch(readLines(output_file, warn = FALSE),
                                 error = function(e2) character(0))
    }
    if (exists("collected_conditions") && length(collected_conditions) > 0) {
      partial_output <- c(partial_output, collected_conditions)
    }

    # Log error if logging is enabled
    if (settings$log_to_file && !is.null(settings$log_file_path) && settings$log_file_path != "") {
      log_error_to_file(code, e$message, settings$log_file_path, agent_id = agent_id)
    }

    # Display the error in the console
    cat("Error:", e$message, "\n")

    # Record error to agent history
    history_entry <- list(
      timestamp = Sys.time(),
      agent_id = if (!is.null(agent_id)) agent_id else "unknown",
      code = code,
      success = FALSE,
      has_plot = FALSE
    )
    .claude_history_env$entries <- c(.claude_history_env$entries, list(history_entry))
    if (length(.claude_history_env$entries) > .claude_history_env$max_entries) {
      .claude_history_env$entries <- utils::tail(.claude_history_env$entries, .claude_history_env$max_entries)
    }

    response <- list(
      success = FALSE,
      error = e$message
    )
    if (length(partial_output) > 0) {
      response$output <- truncate_output(partial_output)
    }
    if (consensus_banner_needed()) {
      response$output <- paste0(
        if (is.null(response$output)) "" else paste0(response$output, "\n\n"),
        CONSENSUS_BANNER
      )
    }
    return(response)
  }, finally = {
    # Unwind any sinks this execution opened
    if (exists("sink_depth")) {
      while (sink.number() > sink_depth) sink()
    }
    # No sink_depth means we failed before opening one. Do NOT pop blindly:
    # console logging keeps a sink of its own underneath, and popping it
    # silently stops the user's console from being recorded.

    # Clean up temporary files
    if (exists("output_file") && file.exists(output_file)) {
      try(file.remove(output_file), silent = TRUE)
    }

    if (!is.null(plot_file_jpeg) && file.exists(plot_file_jpeg)) {
      try(file.remove(plot_file_jpeg), silent = TRUE)
    }

    if (!is.null(plot_file_png) && file.exists(plot_file_png)) {
      try(file.remove(plot_file_png), silent = TRUE)
    }
  })
}

# Parse execution entries out of past session log files on disk. The
# in-memory history dies with the R session; the timestamped logs do not,
# so they are the cross-restart audit trail of who ran what.
past_history_entries <- function(max_files = 5L) {
  settings <- load_claude_settings()
  if (is.null(settings$log_file_path) || !nzchar(settings$log_file_path)) {
    return(list())
  }
  log_dir <- dirname(settings$log_file_path)
  if (!dir.exists(log_dir)) return(list())
  files <- list.files(log_dir, pattern = "^clauder_.*\\.R$", full.names = TRUE)
  files <- setdiff(files, normalizePath(settings$log_file_path, mustWork = FALSE))
  if (length(files) == 0) return(list())
  files <- files[order(file.info(files)$mtime, decreasing = TRUE)]
  files <- utils::head(files, max_files)

  entries <- list()
  for (f in files) {
    lines <- tryCatch(readLines(f, warn = FALSE), error = function(e) character(0))
    starts <- grep("^# --- \\[", lines)
    if (length(starts) == 0) next
    ends <- c(starts[-1] - 1L, length(lines))
    for (k in seq_along(starts)) {
      block <- lines[starts[k]:ends[k]]
      ts <- sub("^# --- \\[(.*)\\] ---$", "\\1", block[1])
      agent_line <- if (length(block) >= 2) block[2] else ""
      agent <- sub("^# Code executed by ([^ ]+).*$", "\\1", agent_line)
      agent <- sub(":$", "", agent)
      code_lines <- block[!grepl("^# --- \\[|^# Code executed by |^# Run by |^# Error: |^#> ", block)]
      code_lines <- code_lines[nzchar(trimws(code_lines))]
      entries[[length(entries) + 1L]] <- list(
        timestamp = suppressWarnings(as.POSIXct(ts)),
        agent_id = agent,
        code = paste(code_lines, collapse = "\n"),
        success = !grepl("(ERROR)", agent_line, fixed = TRUE),
        has_plot = FALSE,
        source_log = basename(f)
      )
    }
  }
  entries
}

#' Query agent execution history
#'
#' @param agent_filter "all", or a specific agent ID to filter by
#' @param requesting_agent The agent making the request (for context)
#' @param last_n Number of entries to return
#' @param include_past Also parse prior session log files on disk, so the
#'   audit trail survives R restarts
#' @return Character string with formatted history
query_agent_history <- function(agent_filter = "all", requesting_agent = NULL,
                                last_n = 20, include_past = FALSE) {
  entries <- .claude_history_env$entries

  if (isTRUE(include_past)) {
    entries <- c(past_history_entries(), entries)
  }

  if (length(entries) == 0) {
    return(if (isTRUE(include_past)) {
      "No execution history in memory and no past session logs found."
    } else {
      "No execution history recorded yet. Pass include_past = TRUE to search prior session logs on disk."
    })
  }

  # Filter by agent if requested
  if (agent_filter != "all") {
    entries <- Filter(function(e) e$agent_id == agent_filter, entries)
  }

  if (length(entries) == 0) {
    return(sprintf(
      "No history found for agent '%s'.%s", agent_filter,
      if (isTRUE(include_past)) "" else
        " Pass include_past = TRUE to also search prior session logs."
    ))
  }

  # Take last N
  if (length(entries) > last_n) {
    entries <- utils::tail(entries, last_n)
  }

  # Format output
  lines <- vapply(entries, function(e) {
    status <- if (e$success) "OK" else "ERR"
    plot_flag <- if (e$has_plot) " [plot]" else ""
    src <- if (!is.null(e$source_log)) paste0(" {", e$source_log, "}") else ""
    code_preview <- substr(gsub("\n", " ", e$code), 1, 80)
    ts_txt <- tryCatch(format(e$timestamp, "%Y-%m-%d %H:%M:%S"),
                       error = function(err) as.character(e$timestamp))
    sprintf("[%s] %s (%s%s)%s: %s",
            ts_txt, e$agent_id, status, plot_flag, src, code_preview)
  }, character(1))

  paste(lines, collapse = "\n")
}

#' Validate code for security issues
#'
#' @param code The R code to validate
#' @return A list with blocked (logical) and reason (character) fields

validate_code_security <- function(code) {
  # System command calls to block completely
  if (grepl("\\bsystem\\s*\\(", code) ||
      grepl("\\bsystem2\\s*\\(", code) ||
      grepl("\\bshell\\s*\\(", code) ||
      grepl("\\bshell\\.exec\\s*\\(", code)) {
    return(list(
      blocked = TRUE,
      reason = "Security restriction: System command execution is not allowed"
    ))
  }
      
  if (grepl("rstudioapi::terminal", code)) {
    return(list(
      blocked = TRUE,
      reason = "Security restriction: Direct terminal access via `rstudioapi` is disabled."
    ))
  }

  # File deletion via base functions
  file_deletion_patterns <- c(
    "\\bunlink\\s*\\([^)]*['\"]\\*['\"][^)]*\\)",  # unlink("*")
    "\\bunlink\\s*\\([^)]*recursive\\s*=\\s*TRUE[^)]*\\)",
    "\\bunlink\\s*\\([^)]*force\\s*=\\s*TRUE[^)]*\\)",
    "\\bfile\\.remove\\s*\\([^)]*['\"]\\*['\"][^)]*\\)"  # file.remove("*")
  )

  # Check file deletion calls
  for (pattern in file_deletion_patterns) {
    if (grepl(pattern, code, ignore.case = TRUE)) {
      return(list(
        blocked = TRUE,
        reason = paste0("Security restriction: Potentially dangerous file deletion operation detected")
      ))
    }
  }

  # Allow everything else
  return(list(blocked = FALSE))
}

# Append what a command printed, under the entry just written for it.
# The "#> " prefix marks these lines as output rather than code, so replay,
# history and notebook export skip them.
log_output_to_file <- function(output, log_path, max_lines = 40L) {
  if (length(output) == 0) return(invisible(NULL))
  if (length(output) > max_lines) {
    output <- c(output[seq_len(max_lines)],
                sprintf("... %d more lines not logged", length(output) - max_lines))
  }
  entry <- paste0(paste0("#> ", output, collapse = "\n"), "\n\n")
  tryCatch(cat(entry, file = log_path, append = TRUE), error = function(e) NULL)
  invisible(NULL)
}

#' Log code to file
#'
#' @param code The R code to log
#' @param log_path The path to the log file
#' @param agent_id Optional agent identifier used to attribute the entry
#' @return Invisible NULL

log_code_to_file <- function(code, log_path, agent_id = NULL) {
  # Create timestamp
  timestamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")

  # Format the log entry with agent attribution
  agent_label <- if (!is.null(agent_id)) agent_id else "Claude"
  log_entry <- sprintf("# --- [%s] ---\n# Code executed by %s:\n%s\n\n", timestamp, agent_label, code)

  # Create directory if it doesn't exist
  log_dir <- dirname(log_path)
  if (!dir.exists(log_dir)) {
    tryCatch({
      dir.create(log_dir, recursive = TRUE)
    }, error = function(e) {
      warning("Could not create log directory: ", e$message)
      return(invisible(NULL))
    })
  }

  # Append to the log file with better error handling
  tryCatch({
    cat(log_entry, file = log_path, append = TRUE)
    # If this is the first entry, print a confirmation message
    if (!file.exists(log_path) || file.info(log_path)$size < 100) {
      message("Created log file at: ", normalizePath(log_path))
    }
  }, error = function(e) {
    warning("Could not write to log file: ", e$message)
  })

  invisible(NULL)
}

#' Log error to file
#'
#' @param code The R code that caused the error
#' @param error_message The error message
#' @param log_path The path to the log file
#' @param agent_id Optional agent identifier used to attribute the entry
#' @return Invisible NULL

log_error_to_file <- function(code, error_message, log_path, agent_id = NULL) {
  # Create timestamp
  timestamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")

  # Format the log entry with agent attribution
  agent_label <- if (!is.null(agent_id)) agent_id else "Claude"
  log_entry <- sprintf("# --- [%s] ---\n# Code executed by %s (ERROR):\n%s\n# Error: %s\n\n",
                      timestamp, agent_label, code, error_message)

  # Create directory if it doesn't exist
  log_dir <- dirname(log_path)
  if (!dir.exists(log_dir)) {
    dir.create(log_dir, recursive = TRUE)
  }

  # Append to the log file
  cat(log_entry, file = log_path, append = TRUE)

  invisible(NULL)
}

#' Write reproducibility header to a new log file
#'
#' Captures sessionInfo(), working directory, and timestamp at the top of the log.
#' Called once when a new log file is created.
#'
#' @param log_path The path to the log file
#' @return Invisible NULL

write_log_header <- function(log_path) {
  log_dir <- dirname(log_path)
  if (!dir.exists(log_dir)) {
    dir.create(log_dir, recursive = TRUE)
  }

  # Capture sessionInfo as text
  si <- utils::capture.output(utils::sessionInfo())

  header <- paste0(
    "# ============================================================\n",
    "# ClaudeR Session Log\n",
    "# Date: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"), "\n",
    "# Working Directory: ", getwd(), "\n",
    "# ============================================================\n",
    "#\n",
    "# Session Info:\n",
    paste0("# ", si, collapse = "\n"), "\n",
    "#\n",
    "# ============================================================\n\n"
  )

  cat(header, file = log_path, append = FALSE)
  invisible(NULL)
}

#' Export a ClaudeR log file as a clean, runnable R script
#'
#' Strips timestamps, agent labels, and comment headers from a session log,
#' leaving only the executed R code. Error blocks are included as comments.
#'
#' @param log_path Path to the ClaudeR session log file. If NULL, uses the
#'   current session's log file from settings.
#' @param output_path Path to write the clean script. If NULL, writes to
#'   the same directory with "_clean.R" suffix.
#' @param include_errors If TRUE (default), include errored code blocks as
#'   comments. If FALSE, skip them entirely.
#' @return The output path (invisibly).
#' @export

export_log_as_script <- function(log_path = NULL, output_path = NULL, include_errors = TRUE) {
  # Default to current session log

  if (is.null(log_path)) {
    settings <- load_claude_settings()
    if (!settings$log_to_file || is.null(settings$log_file_path)) {
      stop("Logging is not enabled. Pass a log_path explicitly.")
    }
    log_path <- settings$log_file_path
  }

  if (!file.exists(log_path)) {
    stop("Log file not found: ", log_path)
  }

  # Default output path
  if (is.null(output_path)) {
    output_path <- sub("\\.R$", "_clean.R", log_path)
    if (output_path == log_path) {
      output_path <- paste0(log_path, "_clean.R")
    }
  }

  lines <- readLines(log_path, warn = FALSE)

  # Parse log into blocks
  # Blocks start with "# --- [timestamp] ---"
  block_starts <- grep("^# --- \\[", lines)

  if (length(block_starts) == 0) {
    message("No code blocks found in log file.")
    return(invisible(output_path))
  }

  # Determine block boundaries
  block_ends <- c(block_starts[-1] - 1, length(lines))

  clean_lines <- character(0)

  # Write a header for the clean script
  clean_lines <- c(
    "# Clean R script exported from ClaudeR session log",
    paste0("# Source: ", basename(log_path)),
    paste0("# Exported: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
    ""
  )

  for (i in seq_along(block_starts)) {
    block <- lines[block_starts[i]:block_ends[i]]

    # Check if this is an error block
    is_error <- any(grepl("(ERROR)", block, fixed = TRUE))

    # Extract code lines (skip the header comments)
    # Header lines: "# --- [timestamp] ---", "# Code executed by ...", "# Error: ..."
    code_lines <- block[!grepl("^# --- \\[|^# Code executed by |^# Run by |^# Error: |^#> |^#\\s*$", block)]

    # Remove trailing blank lines
    while (length(code_lines) > 0 && code_lines[length(code_lines)] == "") {
      code_lines <- code_lines[-length(code_lines)]
    }

    if (length(code_lines) == 0) next

    if (is_error && include_errors) {
      clean_lines <- c(clean_lines, "# [The following block produced an error]", paste0("# ", code_lines), "")
    } else if (!is_error) {
      clean_lines <- c(clean_lines, code_lines, "")
    }
  }

  writeLines(clean_lines, output_path)
  message("Exported clean script to: ", output_path)
  invisible(output_path)
}

#' Clean a ClaudeR session log by removing error blocks and their duplicates
#'
#' Parses a ClaudeR log file, identifies error blocks, checks whether a fix
#' follows each error, removes the error blocks and any duplicate code blocks
#' that precede them, and writes the cleaned log. Returns a report of what
#' was found and removed.
#'
#' @param log_path Path to the ClaudeR session log file.
#' @param output_path Path to write the cleaned log. If NULL, overwrites the
#'   original file.
#' @return A data frame summarizing the errors found, invisibly.
#' @export

clean_clauder_log <- function(log_path, output_path = NULL) {
  if (!file.exists(log_path)) {
    stop("Log file not found: ", log_path)
  }

  lines <- readLines(log_path, warn = FALSE)

  # Identify block boundaries by header pattern
  header_pattern <- "^# --- \\[.*\\] ---$"
  header_idx <- grep(header_pattern, lines)
  n_blocks <- length(header_idx)

  if (n_blocks == 0) {
    message("No code blocks found in log.")
    return(invisible(data.frame()))
  }

  block_starts <- header_idx
  block_ends <- c(header_idx[-1] - 1, length(lines))

  # The agent line is the line after the header
  agent_lines <- header_idx + 1
  is_error <- grepl("\\(ERROR\\)", lines[agent_lines])

  if (sum(is_error) == 0) {
    message("No error blocks found. Log is clean.")
    return(invisible(data.frame()))
  }

  # Extract code from a block (skip header, agent line, and error messages)
  extract_code <- function(block_idx) {
    s <- block_starts[block_idx] + 2  # skip header + agent line
    e <- block_ends[block_idx]
    if (s > e) return("")
    code_lines <- lines[s:e]
    code_lines <- code_lines[!grepl("^# Error:", code_lines)]
    code_lines <- code_lines[trimws(code_lines) != ""]
    trimws(paste(code_lines, collapse = "\n"))
  }

  blocks_to_remove <- c()
  error_report <- list()

  for (i in which(is_error)) {
    err_code <- extract_code(i)

    # Always remove the error block
    blocks_to_remove <- c(blocks_to_remove, i)

    # Check if the previous block has identical code (duplicate from logging)
    dup_status <- "No previous block"
    if (i > 1) {
      prev_code <- extract_code(i - 1)
      if (identical(trimws(err_code), trimws(prev_code))) {
        blocks_to_remove <- c(blocks_to_remove, i - 1)
        dup_status <- "Removed duplicate"
      } else {
        dup_status <- "No duplicate"
      }
    }

    # Check if a non-error block follows (the fix)
    fix_exists <- FALSE
    fix_preview <- "N/A (last block)"
    if (i < n_blocks) {
      fix_exists <- !grepl("\\(ERROR\\)", lines[agent_lines[i + 1]])
      fix_preview <- substr(extract_code(i + 1), 1, 120)
    }

    # Extract the error message
    err_msg_lines <- lines[block_starts[i]:block_ends[i]]
    err_msg <- paste(err_msg_lines[grepl("^# Error:", err_msg_lines)], collapse = " ")

    error_report[[length(error_report) + 1]] <- data.frame(
      block = i,
      line = block_starts[i],
      error = err_msg,
      duplicate_before = dup_status,
      fix_follows = fix_exists,
      fix_preview = fix_preview,
      stringsAsFactors = FALSE
    )
  }

  report <- do.call(rbind, error_report)

  # Print report
  cat("=== ClaudeR Log Error Report ===\n\n")
  for (r in seq_len(nrow(report))) {
    cat(sprintf("Error %d (block %d, line %d):\n  %s\n  Duplicate: %s | Fix follows: %s\n\n",
        r, report$block[r], report$line[r], report$error[r],
        report$duplicate_before[r], report$fix_follows[r]))
  }

  # Remove error blocks and their duplicates
  blocks_to_remove <- sort(unique(blocks_to_remove))
  lines_to_remove <- c()
  for (b in blocks_to_remove) {
    lines_to_remove <- c(lines_to_remove, block_starts[b]:block_ends[b])
  }

  clean_lines <- lines[-lines_to_remove]

  cat(sprintf("Removed %d blocks (%d lines). %d lines remain.\n",
      length(blocks_to_remove), length(lines_to_remove), length(clean_lines)))

  # Write output
  out <- if (!is.null(output_path)) output_path else log_path
  writeLines(clean_lines, out)
  cat("Written to:", out, "\n")

  invisible(report)
}

#' Search project source files for a pattern
#'
#' @param pattern Regex pattern to search for
#' @param extensions Comma-separated file extensions (default "R,Rmd,qmd")
#' @param root_dir Root directory to search (default ".")
#' @param max_results Maximum matches to return (default 50)
#' @param ignore_case Case-insensitive search (default FALSE)
#' @return Character string of matches
search_project_code_impl <- function(pattern, extensions = "R,Rmd,qmd",
                                     root_dir = ".", max_results = 50L,
                                     ignore_case = FALSE) {
  exts <- trimws(strsplit(extensions, ",")[[1]])
  ext_pattern <- paste0("\\.(", paste(exts, collapse = "|"), ")$")

  all_files <- list.files(root_dir, pattern = ext_pattern,
                          recursive = TRUE, full.names = TRUE,
                          ignore.case = TRUE)
  # Exclude common non-source directories
  all_files <- all_files[!grepl("/(renv|packrat|\\.git)/", all_files)]

  if (length(all_files) == 0) {
    return(paste0("No files with extensions [", extensions, "] found under: ",
                  normalizePath(root_dir, mustWork = FALSE)))
  }

  results <- character(0)
  for (fpath in all_files) {
    lines <- tryCatch(readLines(fpath, warn = FALSE), error = function(e) character(0))
    if (length(lines) == 0) next
    hits <- tryCatch(
      grep(pattern, lines, ignore.case = ignore_case),
      error = function(e) {
        warning("Invalid regex: ", e$message)
        integer(0)
      }
    )
    if (length(hits) == 0) next
    # Prefix-strip without regex: normalizePath output can contain regex
    # metacharacters (+, parens) that would corrupt or crash a sub() pattern
    fp_norm <- normalizePath(fpath, mustWork = FALSE, winslash = "/")
    root_norm <- normalizePath(root_dir, mustWork = FALSE, winslash = "/")
    rel_path <- if (startsWith(fp_norm, root_norm)) {
      sub("^/+", "", substring(fp_norm, nchar(root_norm) + 1L))
    } else {
      fp_norm
    }
    for (ln in hits) {
      results <- c(results, sprintf("%s:%d: %s", rel_path, ln, trimws(lines[ln])))
      if (length(results) >= max_results) break
    }
    if (length(results) >= max_results) break
  }

  if (length(results) == 0) {
    return(paste0("No matches for pattern '", pattern, "' in ", length(all_files), " files."))
  }

  header <- sprintf("Found %d match(es) across %d file(s):\n",
                    length(results), length(unique(sub(":.*", "", results))))
  paste0(header, paste(results, collapse = "\n"))
}

#' Probe R scripts in a clean background session
#'
#' @param script_paths Character vector of script paths to source
#' @param timeout Seconds before timing out (default 60)
#' @param capture_output If TRUE, also capture and return the statistics the
#'   script prints when run (visible top-level expressions included). This
#'   makes the probe a clean-room evaluator: the output comes from a fresh
#'   process, so stale objects in the main session can never contaminate it.
#' @return Character string describing objects created by each script
probe_scripts_impl <- function(script_paths, timeout = 60, capture_output = FALSE) {
  results <- character(0)
  for (sp in script_paths) {
    sp_expanded <- path.expand(sp)
    if (!file.exists(sp_expanded)) {
      results <- c(results, sprintf("--- %s ---\nFile not found.\n", sp))
      next
    }
    probe_result <- tryCatch({
      callr::r(function(script_path, capture_output) {
        # Audit-clean printing inside the clean room too
        options(pillar.sigfig = 7, tibble.print_max = Inf, width = 200, digits = 7)
        env <- new.env(parent = globalenv())
        printed <- character(0)
        summary_txt <- tryCatch({
          if (capture_output) {
            printed <- utils::capture.output(
              source(script_path, local = env, print.eval = TRUE)
            )
          } else {
            source(script_path, local = env)
          }
          obj_names <- ls(env)
          if (length(obj_names) == 0) "No objects created."
          else {
            info <- vapply(obj_names, function(nm) {
              obj <- get(nm, envir = env)
              cl <- paste(class(obj), collapse = "/")
              dims <- if (is.data.frame(obj) || is.matrix(obj)) {
                paste0(" [", nrow(obj), " x ", ncol(obj), "]")
              } else if (is.vector(obj) && !is.list(obj)) {
                paste0(" [length ", length(obj), "]")
              } else {
                ""
              }
              paste0(nm, " : ", cl, dims)
            }, character(1))
            paste(info, collapse = "\n")
          }
        }, error = function(e) {
          paste0("Error sourcing: ", e$message)
        })
        if (capture_output && length(printed) > 0) {
          if (length(printed) > 400) {
            printed <- c(utils::head(printed, 320),
                         sprintf("... [%d lines omitted] ...", length(printed) - 400L),
                         utils::tail(printed, 80))
          }
          out_txt <- paste(printed, collapse = "\n")
          if (nchar(out_txt) > 40000) {
            out_txt <- paste0(substr(out_txt, 1, 40000), "\n... [output truncated]")
          }
          summary_txt <- paste0(summary_txt, "\n--- printed output ---\n", out_txt)
        }
        summary_txt
      }, args = list(script_path = sp_expanded, capture_output = isTRUE(capture_output)),
         user_profile = FALSE, timeout = timeout)
    }, error = function(e) {
      paste0("callr error: ", e$message)
    })
    results <- c(results, sprintf("--- %s ---\n%s\n", sp, probe_result))
  }
  paste(results, collapse = "\n")
}

#' Verify references by looking up DOIs in the CrossRef API
#'
#' @param file_path Path to manuscript or references file
#' @param text Raw text containing references (alternative to file_path)
#' @param start_line Optional start line for reading file
#' @param end_line Optional end line for reading file
#' @return Character string with verification report
verify_references_impl <- function(file_path = NULL, text = NULL,
                                    start_line = NULL, end_line = NULL) {
  if (!requireNamespace("jsonlite", quietly = TRUE)) {
    return("Error: jsonlite package is required. Install with install.packages('jsonlite')")
  }

  # Get text from file or direct input. Manuscripts (.docx/.pdf) route
  # through the structured extractor; a raw readLines() on a .docx returns
  # zip bytes, which is how the Pass 4 line-range mode broke in the field.
  if (!is.null(file_path)) {
    file_path <- path.expand(file_path)
    if (!file.exists(file_path)) {
      return(paste0("Error: File not found: ", file_path))
    }
    lines <- read_as_text_lines(file_path)
    if (!is.null(start_line)) {
      end_l <- if (!is.null(end_line)) min(end_line, length(lines)) else length(lines)
      lines <- lines[max(1, start_line):end_l]
    }
    text <- paste(lines, collapse = "\n")
  } else if (is.null(text)) {
    return("Error: Either file_path or text must be provided")
  }

  # Extract DOIs
  dois <- extract_dois(text)
  doi_pattern <- "10\\.\\d{4,9}/[-._;()/:a-zA-Z0-9]+"

  # Cap per call: each lookup blocks the R session, and the MCP bridge times
  # out at 120s. Large bibliographies should be paged via start_line/end_line.
  max_dois <- 50L
  n_found <- length(dois)
  cap_note <- ""
  if (n_found > max_dois) {
    dois <- dois[seq_len(max_dois)]
    cap_note <- sprintf(
      "NOTE: %d DOIs found; only the first %d were checked. Call again with start_line/end_line to cover the rest.\n",
      n_found, max_dois
    )
  }

  # Bound each CrossRef request; the default timeout (60s) can stack badly
  old_timeout <- options(timeout = 10)
  on.exit(options(old_timeout), add = TRUE)

  # arXiv IDs (new-style NNNN.NNNNN). Checked against the arXiv API, with a
  # published-version lookup so preprint citations of published work surface.
  arxiv_pattern <- "arXiv[:. ]\\s*(\\d{4}\\.\\d{4,5})"
  arxiv_ids <- unique(unlist(lapply(
    regmatches(text, gregexpr(arxiv_pattern, text, perl = TRUE, ignore.case = TRUE)),
    function(m) sub(arxiv_pattern, "\\1", m, perl = TRUE, ignore.case = TRUE)
  )))
  arxiv_ids <- utils::head(arxiv_ids[nzchar(arxiv_ids)], 10L)

  # Reference entries with neither a DOI nor an arXiv ID: try bibliographic
  # matching. Blocks are blank-line-separated chunks of plausible entry size.
  blocks <- strsplit(text, "\n\\s*\n")[[1]]
  nodoi_refs <- utils::head(Filter(function(b) {
    flat <- trimws(gsub("\\s+", " ", b))
    nchar(flat) >= 50 && nchar(flat) <= 600 &&
      !grepl(doi_pattern, b, perl = TRUE) &&
      !grepl(arxiv_pattern, b, perl = TRUE, ignore.case = TRUE)
  }, blocks), 15L)

  if (length(dois) == 0 && length(arxiv_ids) == 0 && length(nodoi_refs) == 0) {
    return(paste0(
      "No DOIs, arXiv IDs, or matchable reference entries found in the specified text.\n",
      "To verify these references, use web search to check each one manually."
    ))
  }

  # Query CrossRef for each DOI
  results <- vector("list", length(dois))
  for (i in seq_along(dois)) {
    doi <- dois[i]
    results[[i]] <- tryCatch({
      api_url <- paste0("https://api.crossref.org/works/", utils::URLencode(doi, reserved = TRUE))
      # Retry transient failures (429 rate limits, hiccups); a 404 is a real
      # answer (unregistered DOI) and is surfaced immediately.
      raw <- NULL
      for (attempt in 1:3) {
        raw <- tryCatch(jsonlite::fromJSON(api_url), error = function(e) e)
        if (!inherits(raw, "error") || grepl("404", conditionMessage(raw))) break
        Sys.sleep(c(1.5, 5)[min(attempt, 2)])
      }
      if (inherits(raw, "error")) stop(raw)
      msg <- raw$message

      title <- if (!is.null(msg$title)) paste(msg$title, collapse = " ") else "N/A"

      authors_df <- msg$author
      authors <- if (!is.null(authors_df) && is.data.frame(authors_df) && nrow(authors_df) > 0) {
        paste(apply(authors_df, 1, function(a) {
          fam <- if (!is.na(a["family"])) a["family"] else ""
          giv <- if (!is.na(a["given"])) substr(a["given"], 1, 1) else ""
          if (nchar(giv) > 0) paste0(fam, ", ", giv, ".") else fam
        }), collapse = "; ")
      } else "N/A"

      year <- "N/A"
      if (!is.null(msg$published) && !is.null(msg$published$`date-parts`)) {
        year <- as.character(msg$published$`date-parts`[[1]][1])
      } else if (!is.null(msg$`published-print`) && !is.null(msg$`published-print`$`date-parts`)) {
        year <- as.character(msg$`published-print`$`date-parts`[[1]][1])
      } else if (!is.null(msg$`published-online`) && !is.null(msg$`published-online`$`date-parts`)) {
        year <- as.character(msg$`published-online`$`date-parts`[[1]][1])
      }

      journal <- if (!is.null(msg$`container-title`) && length(msg$`container-title`) > 0) {
        msg$`container-title`[1]
      } else "N/A"

      doi_url <- if (!is.null(msg$URL)) msg$URL else paste0("https://doi.org/", doi)

      retraction_flag <- check_retraction_impl(doi)

      paste0(
        "DOI: ", doi, "\n",
        "Status: FOUND\n",
        "CrossRef Title: ", title, "\n",
        "CrossRef Authors: ", authors, "\n",
        "CrossRef Year: ", year, "\n",
        "CrossRef Journal: ", journal, "\n",
        "CrossRef URL: ", doi_url,
        if (!is.null(retraction_flag)) paste0("\n", retraction_flag) else ""
      )
    }, error = function(e) {
      if (grepl("404", e$message)) {
        paste0("DOI: ", doi, "\nStatus: NOT FOUND IN CROSSREF\n",
               "This DOI does not resolve. It may be fabricated, malformed, or not yet registered.")
      } else {
        paste0("DOI: ", doi, "\nStatus: ERROR\n", "Error: ", e$message)
      }
    })

    # Polite rate limiting
    if (i < length(dois)) Sys.sleep(0.25)
  }

  # arXiv lookups (with published-version check)
  arxiv_section <- ""
  if (length(arxiv_ids) > 0) {
    arxiv_results <- character(0)
    for (aid in arxiv_ids) {
      r <- check_arxiv_impl(aid)
      if (!is.null(r)) arxiv_results <- c(arxiv_results, r)
      Sys.sleep(0.25)
    }
    if (length(arxiv_results) > 0) {
      arxiv_section <- paste0(
        "\n\n=== ARXIV PREPRINTS (", length(arxiv_ids), ") ===\n\n",
        paste(arxiv_results, collapse = "\n\n")
      )
    }
  }

  # Bibliographic matching for DOI-less entries
  nodoi_section <- ""
  if (length(nodoi_refs) > 0) {
    nodoi_results <- character(0)
    for (ref in nodoi_refs) {
      flat <- trimws(gsub("\\s+", " ", ref))
      m <- match_reference_impl(flat)
      nodoi_results <- c(nodoi_results, paste0(
        "Reference: ", substr(flat, 1, 140), if (nchar(flat) > 140) "..." else "", "\n",
        if (!is.null(m)) m else "No plausible Crossref match; verify manually via web search."
      ))
      Sys.sleep(0.25)
    }
    nodoi_section <- paste0(
      "\n\n=== ENTRIES WITHOUT DOIs (", length(nodoi_refs), ", bibliographic matching) ===\n\n",
      paste(nodoi_results, collapse = "\n\n")
    )
  }

  paste0(
    "=== REFERENCE VERIFICATION REPORT ===\n",
    cap_note,
    "DOIs found: ", n_found, "\n",
    "---\n\n",
    paste(results, collapse = "\n\n---\n\n"),
    arxiv_section,
    nodoi_section,
    "\n\n---\n",
    "Compare CrossRef metadata against manuscript claims.\n",
    "Retraction/correction flags come from Crossref update notices.\n",
    "Bibliographic matches are candidates, not confirmations: verify title and authors before accepting.\n",
    "Anything still unmatched requires manual web search."
  )
}

#' Extract text lines from a manuscript file
#'
#' Reads a manuscript file and returns its text as a character vector of lines
#' with structure preserved: headings are prefixed with `#` marks, and table
#' cells are emitted row-wise as `[Table k, row j] cell | cell | cell` so
#' adjacent numeric cells can never concatenate. Supports .docx (via the
#' officer package), .pdf (via pdftools), .qmd, .Rmd, .tex, .txt, and other
#' plain text formats.
#'
#' @param file_path Path to the manuscript file
#' @return Character vector with one element per line of text
#' @export
extract_manuscript_text <- function(file_path) {
  file_path <- path.expand(file_path)
  if (!file.exists(file_path)) {
    stop(paste0("File not found: ", file_path))
  }
  ext <- tolower(tools::file_ext(file_path))
  if (ext == "docx") {
    if (!requireNamespace("officer", quietly = TRUE)) {
      stop("The 'officer' package is required to read .docx files. Install with: install.packages('officer')")
    }
    doc <- officer::read_docx(file_path)
    content <- officer::docx_summary(doc)

    # Walk the document in order, emitting paragraphs, headings, and table
    # cells. Table cells get explicit row-wise separators so numbers from
    # adjacent cells can never concatenate into garbage tokens -- and so the
    # audit actually sees table content at all (the old implementation kept
    # only paragraphs and silently dropped every table).
    out <- character(0)
    table_counter <- 0L
    content <- content[order(content$doc_index), , drop = FALSE]
    is_cell <- content$content_type == "table cell"
    runs <- rle(is_cell)
    seg_end <- cumsum(runs$lengths)
    seg_start <- c(1L, utils::head(seg_end, -1L) + 1L)

    emit_table <- function(cells) {
      table_counter <<- table_counter + 1L
      for (r in sort(unique(cells$row_id))) {
        rcells <- cells[cells$row_id == r, , drop = FALSE]
        rcells <- rcells[order(rcells$cell_id), , drop = FALSE]
        vals <- rcells$text
        vals[is.na(vals)] <- ""
        is_hdr <- isTRUE(any(rcells$is_header))
        out <<- c(out, sprintf(
          "[Table %d, %s] %s",
          table_counter,
          if (is_hdr) "header" else paste0("row ", r),
          paste(vals, collapse = " | ")
        ))
      }
      out <<- c(out, "")
    }

    for (seg in seq_along(runs$values)) {
      seg_rows <- content[seg_start[seg]:seg_end[seg], , drop = FALSE]
      if (!runs$values[seg]) {
        # Paragraph segment: emit each paragraph, marking headings
        for (k in seq_len(nrow(seg_rows))) {
          txt <- seg_rows$text[k]
          if (is.na(txt)) txt <- ""
          style <- seg_rows$style_name[k]
          if (!is.na(style) && grepl("heading", style, ignore.case = TRUE)) {
            lvl <- suppressWarnings(as.integer(gsub("\\D", "", style)))
            if (is.na(lvl) || lvl < 1) lvl <- 1L
            txt <- paste0(strrep("#", min(lvl, 6L)), " ", txt)
          }
          out <- c(out, txt)
        }
      } else {
        # Table segment. Adjacent tables with no paragraph between them
        # arrive as one run; a row_id that resets below its predecessor
        # marks the boundary.
        breaks <- which(diff(seg_rows$row_id) < 0 &
                          seg_rows$cell_id[-1] <= seg_rows$cell_id[-nrow(seg_rows)])
        starts <- c(1L, breaks + 1L)
        ends <- c(breaks, nrow(seg_rows))
        for (t in seq_along(starts)) {
          emit_table(seg_rows[starts[t]:ends[t], , drop = FALSE])
        }
      }
    }
    return(out)
  } else if (ext == "pdf") {
    if (!requireNamespace("pdftools", quietly = TRUE)) {
      stop("The 'pdftools' package is required to read .pdf files. Install with: install.packages('pdftools')")
    }
    pages <- pdftools::pdf_text(file_path)
    lines <- unlist(strsplit(pages, "\n"))
    return(lines)
  } else {
    return(readLines(file_path, warn = FALSE))
  }
}

#' Print the Data Annotation prompt template
#'
#' Displays the built-in protocol for AI-driven CSV data annotation using
#' the load_annotation_data and annotate MCP tools.
#'
#' @return The prompt text (invisibly), printed to the console.
#' @export
data_annotation_prompt <- function() {
  prompt_path <- system.file("prompts", "data_annotation.md", package = "ClaudeR")
  if (!nzchar(prompt_path) || !file.exists(prompt_path)) {
    stop("Data annotation prompt template not found. Is ClaudeR installed correctly?")
  }
  txt <- paste(readLines(prompt_path, warn = FALSE), collapse = "\n")
  cat(txt, "\n")
  invisible(txt)
}

#' Print the Reviewer Zero prompt template
#'
#' Displays the built-in Reviewer Zero academic auditing protocol.
#' This prompt guides an AI assistant through a 4-pass verification of
#' quantitative claims in a manuscript against source code, with two
#' optional extension passes.
#'
#' @param prereg_path Optional path to a preregistration file (.docx, .pdf,
#'   .qmd, .md, or plain text). When supplied, a Pass 5 is appended that
#'   audits the executed analysis against the preregistered plan and
#'   produces a deviation report (followed / disclosed deviation /
#'   undisclosed deviation / not executed), plus a list of unlabelled
#'   exploratory additions.
#' @param robustness Logical. When TRUE, a Pass 6 is appended that runs a
#'   specification-curve robustness check on the manuscript's primary
#'   claims: the agent enumerates defensible alternative analysis choices,
#'   fans the grid out through background jobs, and reports a sensitivity
#'   table and specification curve.
#' @param writeback Logical. When TRUE (and the manuscript is a .docx), a
#'   final step is appended: every flagged claim is written back into the
#'   manuscript as a native Word comment via [annotate_manuscript()], so
#'   findings can be accepted or dismissed in Word. The annotated copy is
#'   written alongside the original, which is never modified.
#' @param referee Logical. When TRUE, Referee Mode is appended: a
#'   substantive review of the manuscript's reasoning. Five content-only
#'   lenses (logic, methods, internal consistency, evidence presentation,
#'   framing) run as parallel subagents where the host CLI supports them, a
#'   deterministic cross-reference check runs alongside, every finding is
#'   anchor-verified against the text, and confirmed findings are written
#'   into the .docx as Word comments. Also available standalone via
#'   [referee_prompt()].
#' @return The prompt text (invisibly), printed to the console.
#' @export
reviewer_zero_prompt <- function(prereg_path = NULL, robustness = FALSE,
                                 writeback = FALSE, referee = FALSE) {
  prompt_path <- system.file("prompts", "reviewer_zero.md", package = "ClaudeR")
  if (!nzchar(prompt_path) || !file.exists(prompt_path)) {
    stop("Reviewer Zero prompt template not found. Is ClaudeR installed correctly?")
  }
  txt <- paste(readLines(prompt_path, warn = FALSE), collapse = "\n")

  if (!is.null(prereg_path)) {
    prereg_path <- path.expand(prereg_path)
    if (!file.exists(prereg_path)) {
      stop("Preregistration file not found: ", prereg_path, call. = FALSE)
    }
    ext_path <- system.file("prompts", "reviewer_zero_prereg.md", package = "ClaudeR")
    ext <- paste(readLines(ext_path, warn = FALSE), collapse = "\n")
    ext <- gsub("{{PREREG_PATH}}", prereg_path, ext, fixed = TRUE)
    txt <- paste0(txt, "\n", ext)
  }

  if (isTRUE(robustness)) {
    ext_path <- system.file("prompts", "reviewer_zero_robustness.md", package = "ClaudeR")
    ext <- paste(readLines(ext_path, warn = FALSE), collapse = "\n")
    txt <- paste0(txt, "\n", ext)
  }

  if (isTRUE(writeback)) {
    ext_path <- system.file("prompts", "reviewer_zero_writeback.md", package = "ClaudeR")
    ext <- paste(readLines(ext_path, warn = FALSE), collapse = "\n")
    txt <- paste0(txt, "\n", ext)
  }

  if (isTRUE(referee)) {
    txt <- paste0(txt, "\n", build_referee_text())
  }

  cat_protocol(txt)
  invisible(txt)
}

# Build the Referee Mode protocol text with a concrete run configuration.
# Shared by referee_prompt() and reviewer_zero_prompt(referee = TRUE).
build_referee_text <- function(lenses = c("logic", "methods", "consistency",
                                          "evidence", "framing"),
                               reviewers_per_lens = 1L,
                               model = NULL,
                               cross_vendor = FALSE,
                               stance = c("balanced", "reviewer2")) {
  stance <- match.arg(stance)
  valid <- c("logic", "methods", "consistency", "evidence", "framing")
  bad <- setdiff(lenses, valid)
  if (length(bad) > 0) {
    stop(sprintf("Unknown lens(es): %s. Valid: %s.",
                 paste(bad, collapse = ", "), paste(valid, collapse = ", ")),
         call. = FALSE)
  }
  if (!is.numeric(reviewers_per_lens) || reviewers_per_lens < 1 ||
      reviewers_per_lens > 3) {
    stop("`reviewers_per_lens` must be 1, 2, or 3 (stances: balanced; prosecutor+verifier; +backwards reader).",
         call. = FALSE)
  }
  reviewers_per_lens <- as.integer(reviewers_per_lens)

  model_directive <- if (is.null(model)) {
    paste0("inherit the session's model for every reviewer subagent. If the ",
           "user asked for a quick pass, prefer a fast tier (e.g. haiku or ",
           "sonnet); for a submission-grade review, prefer the strongest ",
           "tier available (e.g. opus or fable).")
  } else if (is.null(names(model)) && length(model) == 1) {
    sprintf(paste0("pass model = \"%s\" when dispatching EVERY reviewer ",
                   "subagent (the Task tool's model parameter on Claude ",
                   "Code, or your host's equivalent)."), model)
  } else {
    if (is.null(names(model)) || any(!nzchar(names(model)))) {
      stop("`model` must be a single tier or a fully named vector, e.g. c(logic = \"opus\", consistency = \"haiku\").",
           call. = FALSE)
    }
    bad_names <- setdiff(names(model), valid)
    if (length(bad_names) > 0) {
      stop(sprintf("`model` names must be lenses. Unknown: %s.",
                   paste(bad_names, collapse = ", ")), call. = FALSE)
    }
    paste0("per-lens models: ",
           paste(sprintf("%s -> \"%s\"", names(model), model), collapse = "; "),
           "; lenses not listed inherit the session's model.")
  }

  vendor_directive <- if (isTRUE(cross_vendor)) {
    paste0(
      "ENABLED. Where another vendor's CLI is installed (check with ",
      "`which codex agy qwen` from Bash), dispatch at least one reviewer of ",
      "the logic and methods lenses to a DIFFERENT model vendor as a ",
      "one-shot subprocess: `codex exec` (pipe the reviewer prompt via ",
      "stdin; flags: --skip-git-repo-check -c mcp_servers={}), ",
      "`agy -p \"<prompt>\"`, or `qwen --prompt \"<prompt>\"`. First write ",
      "the extracted manuscript to a plain-text file ",
      "(writeLines(doc_lines, \"ms_extract.txt\")) and reference that path ",
      "in the prompt, along with the lens mandate, stance, and the finding ",
      "format. Cross-vendor findings enter the same registry and the same ",
      "adjudication. Agreement across vendors is strong corroboration; ",
      "vendor-unique findings deserve scrutiny in both directions. If no ",
      "other vendor CLI is available, record that in the report and proceed ",
      "single-vendor. Same-model reviewers share blind spots; a second ",
      "vendor is the strongest decorrelation available."
    )
  } else {
    "disabled for this run: all reviewers run as host-native subagents."
  }

  prompt_path <- system.file("prompts", "reviewer_zero_referee.md", package = "ClaudeR")
  if (!nzchar(prompt_path) || !file.exists(prompt_path)) {
    stop("Referee prompt template not found. Is ClaudeR installed correctly?")
  }
  txt <- paste(readLines(prompt_path, warn = FALSE), collapse = "\n")
  stance_block <- if (identical(stance, "reviewer2")) {
    paste0(
      "\nStance for this run: HOSTILE BUT FAIR REVIEWER 2.\n\n",
      "### Step R0: Unprimed read (FIRST, before any lens work)\n\n",
      "Before applying any lens or reading any registry, give your unprimed\n",
      "read in exactly three sentences: what is the paper's central claim,\n",
      "and would you accept it at a strong venue as it stands? Record these\n",
      "three sentences in the report verbatim, written before any detailed\n",
      "finding exists, so the gestalt judgment is not contaminated by the\n",
      "defect hunt that follows.\n\n",
      "Tone for all comments: direct, skeptical, and unsparing about\n",
      "weaknesses, while remaining scrupulously fair. Every criticism is\n",
      "anchored and defensible; no sneering; genuine strengths are\n",
      "acknowledged where they bear on the accept judgment. Rank the final\n",
      "findings by severity, and tag each with the study it concerns.\n"
    )
  } else ""

  severity_scale <- if (identical(stance, "reviewer2")) {
    paste0("`fatal` (invalidates a central claim; sinks the paper at a strong\n",
           "  venue) / `must-fix` (blocks acceptance until addressed) /\n",
           "  `minor` (substantive but small)")
  } else {
    paste0("`major` (undermines a conclusion) / `moderate` (weakens or\n",
           "  confuses an argument) / `minor` (substantive but small)")
  }

  txt <- gsub("{{LENSES}}", paste(lenses, collapse = ", "), txt, fixed = TRUE)
  txt <- gsub("{{REVIEWERS_PER_LENS}}", as.character(reviewers_per_lens), txt, fixed = TRUE)
  txt <- gsub("{{MODEL_DIRECTIVE}}", model_directive, txt, fixed = TRUE)
  txt <- gsub("{{VENDOR_DIRECTIVE}}", vendor_directive, txt, fixed = TRUE)
  txt <- gsub("{{STANCE_BLOCK}}", stance_block, txt, fixed = TRUE)
  txt <- gsub("{{SEVERITY_SCALE}}", severity_scale, txt, fixed = TRUE)
  txt
}

#' Print the Referee Mode prompt (standalone)
#'
#' Referee Mode is a substantive review of a manuscript's reasoning:
#' argument logic, methods, internal consistency, evidence presentation,
#' and framing, plus a deterministic cross-reference check. Findings are
#' anchor-verified against the text and delivered as Word comments in the
#' manuscript itself. This prints the protocol standalone, without the
#' numeric audit passes; to run it after a full audit, use
#' `reviewer_zero_prompt(referee = TRUE)`.
#'
#' @param lenses Which review lenses to run. Any subset of
#'   `c("logic", "methods", "consistency", "evidence", "framing")`.
#' @param reviewers_per_lens 1, 2, or 3 independent reviewers per lens.
#'   With 2, each lens gets a prosecutor (hunts flaws) and a verifier
#'   (confirms each step); with 3, a backwards reader is added. Opposed
#'   stances decorrelate reviewers built on the same model.
#' @param model Optional model directive for reviewer subagents. A single
#'   tier applies to all lenses (e.g. `"haiku"` for a quick pass,
#'   `"opus"` for a submission-grade review); a named vector sets tiers
#'   per lens, e.g. `c(logic = "opus", consistency = "haiku")`. The
#'   orchestrating agent passes this to its subagent dispatch (Claude
#'   Code's Task tool `model` parameter). Default: inherit the session's
#'   model.
#' @param cross_vendor If TRUE, the protocol instructs the orchestrator to
#'   dispatch at least one logic and one methods reviewer to a different
#'   model vendor (codex/agy/qwen one-shot CLI calls) where installed.
#'   Cross-vendor agreement is the strongest available guard against
#'   same-model blind spots.
#' @param stance `"balanced"` (default) or `"reviewer2"`. Reviewer 2 is a
#'   hostile-but-fair journal reviewer: the run opens with an unprimed read
#'   (three sentences: the paper's central claim, and would it be accepted
#'   at a strong venue) recorded before any lens work, findings use a
#'   fatal / must-fix / minor severity scale, and every finding is tagged
#'   with the study it concerns.
#' @return The prompt text (invisibly), printed to the console.
#' @export
referee_prompt <- function(lenses = c("logic", "methods", "consistency",
                                      "evidence", "framing"),
                           reviewers_per_lens = 1L,
                           model = NULL,
                           cross_vendor = FALSE,
                           stance = c("balanced", "reviewer2")) {
  txt <- build_referee_text(lenses = lenses,
                            reviewers_per_lens = reviewers_per_lens,
                            model = model, cross_vendor = cross_vendor,
                            stance = stance)
  cat_protocol(txt)
  invisible(txt)
}

# Print a protocol, but write the composed text to a file first and announce
# the path. Long protocols exceed the console-output cap (agents saw "262
# lines elided" mid-protocol in the field); the file makes the full text one
# read_file call away.
cat_protocol <- function(txt) {
  proto_file <- tempfile(pattern = "clauder_protocol_", fileext = ".md")
  ok <- tryCatch({ writeLines(txt, proto_file); TRUE }, error = function(e) FALSE)
  if (ok) {
    cat("[Full protocol saved to:", proto_file,
        "-- if this printout is truncated, read that file completely before starting.]\n\n")
  }
  cat(txt, "\n")
  invisible(NULL)
}

#' Print the R Best Practices prompt template
#'
#' Displays the built-in R statistical analysis protocol based on
#' best practices for transparent, reproducible, theory-driven analysis.
#'
#' @return The prompt text (invisibly), printed to the console.
#' @export
r_best_practices_prompt <- function() {
  prompt_path <- system.file("prompts", "r_best_practices.md", package = "ClaudeR")
  if (!nzchar(prompt_path) || !file.exists(prompt_path)) {
    stop("R Best Practices prompt template not found. Is ClaudeR installed correctly?")
  }
  txt <- paste(readLines(prompt_path, warn = FALSE), collapse = "\n")
  cat(txt, "\n")
  invisible(txt)
}

#' Print the Multi-Agent Coordination prompt template
#'
#' Displays the built-in protocol for coordinating multiple AI agents
#' in a shared RStudio session. Covers planning, task claiming, handoffs,
#' and cross-checking.
#'
#' @return The prompt text (invisibly), printed to the console.
#' @export
multi_agent_prompt <- function() {
  prompt_path <- system.file("prompts", "multi_agent.md", package = "ClaudeR")
  if (!nzchar(prompt_path) || !file.exists(prompt_path)) {
    stop("Multi-Agent prompt template not found. Is ClaudeR installed correctly?")
  }
  txt <- paste(readLines(prompt_path, warn = FALSE), collapse = "\n")
  cat(txt, "\n")
  invisible(txt)
}

#' Validate that an assembly review round is structurally complete
#'
#' Deterministic check the orchestrator must call at the end of each assembly
#' round before declaring it resolved. Throws an informative R-level error on
#' any structural failure: missing voters, missing re-verification sections in
#' Round 2+, forbidden patterns (e.g. self-simulated votes), or unrecognized
#' verdicts. Returns invisibly on success so the orchestrator can confirm
#' which checks passed.
#'
#' This is intentionally a hard gate. Soft "you should reject..." rules in the
#' protocol are not reliably followed by orchestrator agents; an R function
#' that errors loudly is.
#'
#' @param lab_folder Absolute path to the lab folder
#' @param round_n Integer round number to validate (1, 2, ...)
#' @param expected_roles Character vector of roles that should have voted in
#'   this round. Default is the four Phase-1 working roles.
#' @return Invisibly returns a list with `valid = TRUE`, the voted roles, and
#'   the verdicts seen for the round.
#' @export
validate_assembly_round <- function(lab_folder,
                                     round_n,
                                     expected_roles = c("eda", "modeling", "reviewer_zero", "reporting")) {
  if (missing(lab_folder) || !nzchar(lab_folder)) {
    stop("`lab_folder` is required.", call. = FALSE)
  }
  if (!dir.exists(lab_folder)) {
    stop(sprintf("Lab folder not found: %s", lab_folder), call. = FALSE)
  }
  if (!is.numeric(round_n) || round_n < 1) {
    stop("`round_n` must be a positive integer.", call. = FALSE)
  }
  round_n <- as.integer(round_n)

  log_path <- file.path(lab_folder, "assembly_log.md")
  if (!file.exists(log_path)) {
    stop(sprintf("assembly_log.md not found in lab folder: %s", log_path), call. = FALSE)
  }

  log_text <- paste(readLines(log_path, warn = FALSE), collapse = "\n")

  # Forbidden pattern: simulated votes. Only flag lines mentioning both
  # "simulat*" and "vote" -- a bare "simulat" match would reject legitimate
  # analysis discussion (Monte Carlo simulations, simulation studies).
  log_lines <- strsplit(log_text, "\n", fixed = TRUE)[[1]]
  sim_vote <- grepl("simulat", log_lines, ignore.case = TRUE) &
    grepl("vote", log_lines, ignore.case = TRUE)
  if (any(sim_vote)) {
    stop(sprintf(
      "assembly_log.md appears to contain a simulated vote (line %d: '%s'). Self-simulated votes are forbidden (see protocol section 3.4).",
      which(sim_vote)[1], trimws(log_lines[which(sim_vote)[1]])
    ), call. = FALSE)
  }

  # Isolate the section for round_n.
  round_pattern <- sprintf("## Round %d\\b", round_n)
  if (!grepl(round_pattern, log_text)) {
    stop(sprintf("Round %d section not found in assembly_log.md.", round_n), call. = FALSE)
  }
  # Get everything from "## Round N" to the next "## Round" or end of file.
  section_start <- regexpr(round_pattern, log_text)
  section_text <- substring(log_text, section_start)
  next_round_match <- regexpr(sprintf("## Round %d\\b", round_n + 1L), section_text)
  if (next_round_match > 0) {
    section_text <- substring(section_text, 1, next_round_match - 1L)
  }

  # Pull every "### Vote <separator> <role>" header. The protocol shows a
  # middle-dot separator but agents may render it differently; match any short
  # non-alphanumeric run between "Vote" and the role name.
  vote_matches <- regmatches(section_text, gregexpr("### Vote[^A-Za-z0-9\n]+([A-Za-z0-9_-]+)", section_text))[[1]]
  found_roles <- sub("^### Vote[^A-Za-z0-9\n]+", "", vote_matches)
  found_roles <- unique(found_roles)
  missing_roles <- setdiff(expected_roles, found_roles)
  if (length(missing_roles) > 0) {
    stop(sprintf(
      "Round %d is missing votes from these expected roles: %s. Every dispatched voter must have a row (APPROVE / CONCERNS / UNAVAILABLE). Silent absence is forbidden.",
      round_n, paste(missing_roles, collapse = ", ")
    ), call. = FALSE)
  }

  # Pull every Verdict line and validate the values.
  verdict_matches <- regmatches(section_text, gregexpr("\\*\\*Verdict:\\*\\*\\s*([A-Z]+)", section_text))[[1]]
  verdicts <- sub("\\*\\*Verdict:\\*\\*\\s*", "", verdict_matches)
  if (length(verdicts) < length(expected_roles)) {
    stop(sprintf(
      "Round %d has %d Verdict rows but expected at least %d (one per role).",
      round_n, length(verdicts), length(expected_roles)
    ), call. = FALSE)
  }
  valid_verdicts <- c("APPROVE", "CONCERNS", "UNAVAILABLE")
  bad <- setdiff(verdicts, valid_verdicts)
  if (length(bad) > 0) {
    stop(sprintf(
      "Round %d has unrecognized verdicts: %s. Allowed values: %s.",
      round_n, paste(bad, collapse = ", "), paste(valid_verdicts, collapse = ", ")
    ), call. = FALSE)
  }

  # For Round 2+, every APPROVE vote must contain a Re-verification section.
  if (round_n >= 2L && any(verdicts == "APPROVE")) {
    # Split section_text into per-vote chunks at each "### Vote " heading.
    # (?s) lets .*? cross newlines -- without it the pattern matches nothing
    # on real multi-line vote blocks and this gate silently never fires.
    vote_chunk_pattern <- "(?s)### Vote[^A-Za-z0-9\n]+[^\n]*\n.*?(?=### Vote|\\Z)"
    vote_chunks <- regmatches(section_text, gregexpr(vote_chunk_pattern, section_text, perl = TRUE))[[1]]
    if (length(vote_chunks) == 0) {
      stop(sprintf(
        "Round %d: could not parse any vote sections for re-verification checking. The log's vote format may be malformed.",
        round_n
      ), call. = FALSE)
    }
    for (chunk in vote_chunks) {
      if (grepl("\\*\\*Verdict:\\*\\*\\s*APPROVE", chunk)) {
        if (!grepl("Re-verification of my Round", chunk)) {
          stop(sprintf(
            "Round %d has an APPROVE vote without a 'Re-verification of my Round N-1 concerns' section. Round 2+ APPROVE votes MUST include this section. Reject the vote and ask the voter to redo it.",
            round_n
          ), call. = FALSE)
        }
      }
    }
  }

  invisible(list(
    valid = TRUE,
    round = round_n,
    voted_roles = found_roles,
    verdicts = verdicts
  ))
}

#' Finalize a Lab Mode session -- hard gate before delivery
#'
#' Runs the full termination-invariant check and, on success, writes a
#' `lab_session_locked.json` file inside the lab folder. The protocol requires
#' the orchestrator to call this function before Phase 4 and reach success.
#' The lock file is the deterministic completion signal -- the user can verify
#' in one line whether the session was properly finalized.
#'
#' Throws an R-level error on any failure, with a specific message identifying
#' what's wrong.
#'
#' @param lab_folder Absolute path to the lab folder
#' @param expected_roles Character vector of roles expected in the final round
#' @param allow_override Logical. If TRUE, allows finalization even if the
#'   final round has CONCERNS or UNAVAILABLE -- but the user must have signaled
#'   override (the function writes the lock file with `override = TRUE` so the
#'   user can audit). Default FALSE.
#' @return Invisibly returns the contents of the written lock file.
#' @export
finalize_lab_session <- function(lab_folder,
                                  expected_roles = c("eda", "modeling", "reviewer_zero", "reporting"),
                                  allow_override = FALSE) {
  if (missing(lab_folder) || !nzchar(lab_folder)) {
    stop("`lab_folder` is required.", call. = FALSE)
  }
  if (!dir.exists(lab_folder)) {
    stop(sprintf("Lab folder not found: %s", lab_folder), call. = FALSE)
  }

  # All required artifacts must exist before delivery.
  required <- c("ledger.md", "analysis_final.R", "validator_report.md", "assembly_log.md")
  missing_files <- required[!file.exists(file.path(lab_folder, required))]
  if (length(missing_files) > 0) {
    stop(sprintf(
      "Lab folder missing required artifacts: %s. The session cannot be finalized.",
      paste(missing_files, collapse = ", ")
    ), call. = FALSE)
  }
  writeup_files <- list.files(lab_folder, pattern = "^final_writeup\\.(md|qmd)$", full.names = FALSE)
  if (length(writeup_files) == 0) {
    stop("Lab folder has no final_writeup.md or final_writeup.qmd. The session cannot be finalized.",
         call. = FALSE)
  }

  # Identify the final round in assembly_log.md.
  log_text <- paste(readLines(file.path(lab_folder, "assembly_log.md"), warn = FALSE), collapse = "\n")
  fin_lines <- strsplit(log_text, "\n", fixed = TRUE)[[1]]
  fin_sim <- grepl("simulat", fin_lines, ignore.case = TRUE) &
    grepl("vote", fin_lines, ignore.case = TRUE)
  if (any(fin_sim)) {
    stop("assembly_log.md appears to contain a simulated vote. Self-simulated votes are forbidden.", call. = FALSE)
  }
  round_headers <- regmatches(
    log_text,
    gregexpr("## Round (\\d+)", log_text)
  )[[1]]
  round_numbers <- as.integer(sub("## Round ", "", round_headers, fixed = TRUE))
  if (length(round_numbers) == 0) {
    stop("assembly_log.md has no Round sections. Cannot identify a final round.", call. = FALSE)
  }
  final_round <- max(round_numbers)

  # Per-round structural check on the final round.
  per_round <- validate_assembly_round(lab_folder, final_round, expected_roles)

  # The final round must be unanimous APPROVE with zero UNAVAILABLE
  # -- unless the caller passed allow_override = TRUE.
  unanimous_approve <- all(per_round$verdicts == "APPROVE")
  if (!unanimous_approve && !isTRUE(allow_override)) {
    bad <- per_round$verdicts[per_round$verdicts != "APPROVE"]
    stop(sprintf(
      "Final round (Round %d) is not unanimous APPROVE -- saw verdicts: %s. The session cannot be finalized without either resolving these or passing allow_override = TRUE.",
      final_round, paste(bad, collapse = ", ")
    ), call. = FALSE)
  }

  result <- list(
    complete = TRUE,
    override = isTRUE(allow_override) && !unanimous_approve,
    lab_folder = normalizePath(lab_folder, mustWork = FALSE),
    final_round = final_round,
    voted_roles = per_round$voted_roles,
    verdicts = per_round$verdicts,
    writeup_file = writeup_files[1],
    validated_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  )

  lock_path <- file.path(lab_folder, "lab_session_locked.json")
  jsonlite::write_json(result, lock_path, auto_unbox = TRUE, pretty = TRUE)

  message(sprintf("Lab session finalized. Lock file written to %s", lock_path))
  invisible(result)
}

#' Print the Lab Mode orchestration protocol
#'
#' Displays the built-in multi-agent research lab protocol. An orchestrator
#' agent reads this protocol and dispatches specialist subagents (EDA,
#' modeling, reviewer_zero, reporting) through parallel exploration, sequential
#' synthesis, and an assembly review until the final deliverables are
#' pristine. Maintains a markdown ledger of findings, snapshots every assembly
#' round to disk, and produces a self-contained timestamped lab folder.
#'
#' Agent-agnostic: works on any host CLI with subagent primitives (Claude Code
#' Task tool, Codex `[agents]`, Gemini CLI `/subagents`, Antigravity
#' `invoke_subagent`). Falls back to sequential role-playing on single-agent
#' CLIs.
#'
#' @param description Required. A research question or task statement. The
#'   orchestrator will refuse to proceed if this is empty or too vague.
#' @param roles Character vector of roles to dispatch in the parallel
#'   exploration phase. Default: all four. Must be a subset of
#'   `c("eda", "modeling", "reviewer_zero", "reporting")`.
#' @param session_name Name of the RStudio session to connect to. Default
#'   `"default"`. Use `list_sessions` to see what's available.
#' @param project_dir Working directory where the lab folder will be created.
#'   Default `"."`.
#' @param output_subdir Subdirectory of `project_dir` that will contain the
#'   timestamped lab folder. Default `"clauder_lab"`. Each invocation produces
#'   a new timestamped subfolder so prior runs are never overwritten.
#' @param max_assembly_rounds Maximum assembly review rounds before
#'   escalating to the user. Default 3.
#'
#' @return The prompt text (invisibly), printed to the console.
#' @export
#' @examples
#' \dontrun{
#' ClaudeR::lab_mode_prompt(
#'   description = "Does driving behavior moderate the relationship between
#'                  horsepower and fuel economy in mtcars?",
#'   session_name = "study_01"
#' )
#' }
lab_mode_prompt <- function(description,
                            roles = c("eda", "modeling", "reviewer_zero", "reporting"),
                            session_name = "default",
                            project_dir = ".",
                            output_subdir = "clauder_lab",
                            max_assembly_rounds = 3) {
  if (missing(description) || !nzchar(trimws(description))) {
    stop("`description` is required and must be a non-empty research question or task statement.",
         call. = FALSE)
  }
  valid_roles <- c("eda", "modeling", "reviewer_zero", "reporting")
  bad <- setdiff(roles, valid_roles)
  if (length(bad) > 0) {
    stop(sprintf("Unknown role(s): %s. Valid roles: %s.",
                 paste(bad, collapse = ", "), paste(valid_roles, collapse = ", ")),
         call. = FALSE)
  }
  if (!is.numeric(max_assembly_rounds) || max_assembly_rounds < 1) {
    stop("`max_assembly_rounds` must be a positive integer.", call. = FALSE)
  }

  prompt_path <- system.file("prompts", "lab_mode.md", package = "ClaudeR")
  if (!nzchar(prompt_path) || !file.exists(prompt_path)) {
    stop("Lab Mode prompt template not found. Is ClaudeR installed correctly?")
  }

  # Build the timestamped lab folder path that will appear in the printed protocol.
  # Normalize to an absolute path so the orchestrator does not nest folders when
  # its working directory has already been changed (e.g. into a prior lab folder).
  # Forward slashes everywhere: this path is substituted into R snippets in
  # the protocol text, and Windows backslashes would make them unparseable.
  project_dir <- normalizePath(project_dir, mustWork = FALSE, winslash = "/")

  # If the resolved project_dir is itself inside a previous clauder_lab_* run,
  # walk back up to a neutral parent so the new run doesn't get buried under
  # prior runs. This handles the case where the user's R session has a stale
  # working directory inside an old lab folder.
  parts <- strsplit(project_dir, "/", fixed = TRUE)[[1]]
  if (length(parts) > 0 && parts[1] == "") parts <- parts[-1]  # drop leading "" from absolute paths
  nested_idx <- which(grepl("^clauder_lab_", parts))[1]
  if (!is.na(nested_idx)) {
    parent_parts <- if (nested_idx > 1) parts[seq_len(nested_idx - 1)] else character(0)
    if (length(parent_parts) > 0 && parent_parts[length(parent_parts)] == output_subdir) {
      parent_parts <- parent_parts[-length(parent_parts)]
    }
    neutral_dir <- if (length(parent_parts) > 0) paste0("/", paste(parent_parts, collapse = "/")) else "/"
    message(sprintf(
      "Note: project_dir was inside a previous lab folder (%s). Using neutral parent (%s) to prevent nesting. Pass project_dir explicitly to override.",
      project_dir, neutral_dir
    ))
    project_dir <- neutral_dir
  }

  ts <- format(Sys.time(), "%Y%m%d_%H%M%S", tz = "UTC")
  lab_folder <- file.path(
    project_dir, output_subdir,
    sprintf("clauder_lab_%s_%s", session_name, ts)
  )

  txt <- paste(readLines(prompt_path, warn = FALSE), collapse = "\n")
  txt <- gsub("{{DESCRIPTION}}", description, txt, fixed = TRUE)
  txt <- gsub("{{SESSION_NAME}}", session_name, txt, fixed = TRUE)
  txt <- gsub("{{LAB_FOLDER}}", lab_folder, txt, fixed = TRUE)
  txt <- gsub("{{ROLES}}", paste(roles, collapse = ", "), txt, fixed = TRUE)
  txt <- gsub("{{MAX_ROUNDS}}", as.character(as.integer(max_assembly_rounds)), txt, fixed = TRUE)
  # Round placeholder in vote format is left as {{N}} intentionally -- the orchestrator fills it per round.
  txt <- gsub("Round {{N}}", "Round <N>", txt, fixed = TRUE)

  cat(txt, "\n")
  invisible(txt)
}

#' Load Claude settings
#'
#' @return A list containing Claude settings
#' @importFrom utils modifyList

load_claude_settings <- function() {
  # Default settings
  default_settings <- list(
    print_to_console = TRUE,
    # On by default: the log is the audit trail the security model leans on
    log_to_file = TRUE,
    log_file_path = file.path(path.expand("~"), "claude_r_logs.R"),
    # Off by default: enforcing the token rejects any clauder-mcp older than
    # 0.6.0, which would break existing installs on upgrade. Users flip this on
    # once both halves are updated.
    require_token = FALSE
  )

  # Try to load settings from a settings file
  settings_file <- file.path(path.expand("~"), ".claude_r_settings.rds")

  if (file.exists(settings_file)) {
    tryCatch({
      settings <- readRDS(settings_file)
      # Merge with defaults to ensure all fields exist
      settings <- modifyList(default_settings, settings)
      return(settings)
    }, error = function(e) {
      return(default_settings)
    })
  } else {
    return(default_settings)
  }
}

#' Save Claude settings
#'
#' @param settings A list containing Claude settings
#' @return Invisible NULL

save_claude_settings <- function(settings) {
  # Save settings to a settings file
  settings_file <- file.path(path.expand("~"), ".claude_r_settings.rds")
  saveRDS(settings, settings_file)
  invisible(NULL)
}
