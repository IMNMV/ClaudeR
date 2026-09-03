# Console capture: record what the USER runs in the console into the same
# session log the agent writes to, so one file holds both sides of the work.
#
# The pieces, and why each is needed:
#   addTaskCallback        the expression the user typed, and its visible value
#   globalCallingHandlers  warnings and messages (they go to stderr, so a sink
#                          cannot see them; R >= 4.0 lets us observe without
#                          suppressing). CONSTRAINT: it can only be called with
#                          an empty handler stack, i.e. from a bare top-level
#                          console call. Inside a Shiny observer (the addin
#                          checkbox), a task callback, a later() callback, or
#                          tryCatch() it errors "should not be called with
#                          handlers on the stack". So it is attempted only when
#                          sys.nframe() says we are at top level; otherwise
#                          warnings are read from last.warning after each
#                          command instead, and message() output is not captured.
#   options(error=)        uncaught errors
#   sink(split = TRUE)     everything printed as a side effect: cat(), progress
#                          output, print() called inside a function. The task
#                          callback only ever sees the value a command returns,
#                          so without this the log shows f() but not what f()
#                          printed. split = TRUE keeps it visible in the console.
# sink(type = "message") is deliberately NOT used: it cannot split, so it would
# swallow the user's own errors in the console.

.console_state <- new.env(parent = emptyenv())

console_log_path <- function() {
  s <- tryCatch(.claude_server_env$settings, error = function(e) NULL)
  if (is.null(s) || !isTRUE(s$log_to_file)) return(NULL)
  p <- s$log_file_path
  if (is.null(p) || !nzchar(p)) return(NULL)
  p
}

# One writer for every console entry, so the format stays consistent.
console_write <- function(text, tag = "user") {
  p <- console_log_path()
  if (is.null(p)) return(invisible(FALSE))
  ts <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  entry <- sprintf("# --- [%s] ---\n# Run by %s (console):\n%s\n\n", ts, tag, text)
  tryCatch(cat(entry, file = p, append = TRUE), error = function(e) NULL)
  invisible(TRUE)
}

# Trim runaway output so one huge print cannot bloat the log.
console_trim <- function(x, max_lines = 40L) {
  if (length(x) <= max_lines) return(x)
  c(x[seq_len(max_lines)],
    sprintf("# ... %d more lines not logged", length(x) - max_lines))
}

console_note_condition <- function(kind, msg) {
  if (!isTRUE(.console_state$active)) return(invisible(NULL))
  msg <- trimws(paste(msg, collapse = " "))
  if (!nzchar(msg)) return(invisible(NULL))
  .console_state$pending <- c(.console_state$pending,
                              sprintf("#> %s: %s", kind, msg))
  invisible(NULL)
}

# Start teeing stdout to a scratch file. split = TRUE so the console still
# shows everything; we only read a copy.
console_sink_open <- function() {
  f <- tempfile(fileext = ".txt")
  con <- file(f, open = "wt")
  .console_state$sink_file <- f
  .console_state$sink_con <- con
  .console_state$consumed <- 0L
  sink(con, split = TRUE)
  .console_state$sink_owned <- TRUE
  invisible(TRUE)
}

# Pop our sink, being careful not to disturb a capture.output() that an agent
# call may have pushed on top of it.
console_sink_close <- function() {
  con <- .console_state$sink_con
  if (is.null(con)) return(invisible(FALSE))
  tryCatch({
    # Only pop if ours is the sink on top. Popping blindly would remove one
    # that an agent execution opened and leave that execution writing nowhere.
    if (isTRUE(.console_state$sink_owned) && sink.number() > 0) sink()
    .console_state$sink_owned <- FALSE
    flush(con); close(con)
  }, error = function(e) NULL)
  tryCatch(unlink(.console_state$sink_file), error = function(e) NULL)
  .console_state$sink_con <- NULL
  .console_state$sink_file <- NULL
  .console_state$consumed <- 0L
  invisible(TRUE)
}

# Lines printed since the previous command. Reads by offset rather than
# truncating, because reopening the file mid-session corrupts the sink stack.
console_drain <- function() {
  con <- .console_state$sink_con
  f <- .console_state$sink_file
  if (is.null(con) || is.null(f)) return(character(0))
  tryCatch({
    flush(con)
    all <- readLines(f, warn = FALSE)
    seen <- .console_state$consumed %||% 0L
    .console_state$consumed <- length(all)
    if (length(all) > seen) all[(seen + 1L):length(all)] else character(0)
  }, error = function(e) character(0))
}

`%||%` <- function(a, b) if (is.null(a)) b else a

# Our sink can be removed by something else unwinding the sink stack. At top
# level, with every execution finished, ours should be the only one left. If it
# is gone, put it back rather than silently recording nothing from here on.
console_sink_heal <- function() {
  if (!isTRUE(.console_state$active)) return(invisible(FALSE))
  if (isTRUE(.console_state$sink_owned) && sink.number() >= 1) return(invisible(FALSE))
  if (sink.number() != 0) return(invisible(FALSE))
  con <- .console_state$sink_con
  if (!is.null(con)) tryCatch(close(con), error = function(e) NULL)
  tryCatch(console_sink_open(), error = function(e) NULL)
  invisible(TRUE)
}

console_task_callback <- function(expr, value, ok, visible) {
  # A task callback that signals an error is removed by R, which would end
  # console logging silently, so nothing here is allowed to escape.
  tryCatch({
    if (is.null(console_log_path())) return(TRUE)
    code <- paste(deparse(expr), collapse = "\n")

    # Skip our own bookkeeping so the log does not describe itself.
    if (grepl("^(start_console_logging|stop_console_logging|ClaudeR:::)", code)) return(TRUE)

    lines <- character(0)
    printed <- console_drain()
    if (length(printed)) {
      lines <- paste0("#> ", console_trim(printed))
    } else if (isTRUE(visible) && isTRUE(ok)) {
      # Nothing was printed as a side effect, so fall back to the value itself.
      out <- tryCatch(utils::capture.output(print(value)),
                      error = function(e) character(0))
      if (length(out)) lines <- paste0("#> ", console_trim(out))
    }
    if (!isTRUE(ok)) lines <- c(lines, "#> error: command did not complete")
    # Without globalCallingHandlers (see header), pick warnings up from
    # last.warning. It lingers across commands, so only report it when it
    # changed since the previous command.
    if (!isTRUE(.console_state$gch_installed)) {
      lw <- tryCatch(get0("last.warning", envir = baseenv(), inherits = FALSE),
                     error = function(e) NULL)
      if (!is.null(lw) && !identical(lw, .console_state$last_lw)) {
        .console_state$last_lw <- lw
        lines <- c(lines, paste0("#> warning: ", names(lw)))
      }
    }
    if (length(.console_state$pending)) {
      lines <- c(.console_state$pending, lines)
      .console_state$pending <- NULL
    }
    body <- if (length(lines)) paste0(code, "\n", paste(lines, collapse = "\n")) else code
    console_write(body, tag = "user")
  }, error = function(e) NULL)
  tryCatch(console_sink_heal(), error = function(e) NULL)
  TRUE
}

#' Start logging the user's console activity
#'
#' Adds the user's own console commands, and their results, to the session log
#' the agent already writes to. An agent can then read one file and see both
#' sides of the session.
#'
#' @return Invisibly TRUE if capture started.
#' @export
start_console_logging <- function() {
  # Called from the console (top level) OR from the addin's Shiny observer.
  at_top <- sys.nframe() == 1L
  registered <- "clauder_console_log" %in% getTaskCallbackNames()
  if (isTRUE(.console_state$active) && registered) return(invisible(TRUE))
  .console_state$pending <- NULL
  .console_state$last_lw <- tryCatch(get0("last.warning", envir = baseenv(), inherits = FALSE),
                                     error = function(e) NULL)

  # 1. The essential half, first and unconditionally: the task callback that
  #    writes each command. Nothing below may prevent this from being armed.
  if (!registered) {
    .console_state$handle <- addTaskCallback(console_task_callback,
                                             name = "clauder_console_log")
  }

  # 2. Printed output (optional). If the sink cannot be opened we still log
  #    commands and their values.
  ok_sink <- isTRUE(tryCatch({ console_sink_open(); TRUE }, error = function(e) FALSE))

  # 3. Uncaught errors.
  if (is.null(.console_state$old_error_set)) {
    .console_state$old_error <- getOption("error")
    .console_state$old_error_set <- TRUE
  }
  options(error = function() {
    tryCatch({
      msg <- geterrmessage()
      console_write(sprintf("#> error: %s", trimws(msg)), tag = "user")
    }, error = function(e) NULL)
  })

  .console_state$active <- TRUE

  # 4. Warnings and messages via globalCallingHandlers, LAST, and only from a
  #    bare top-level call (see header). Not wrapped in tryCatch: that would
  #    itself put a handler on the stack and guarantee the error.
  if (!isTRUE(.console_state$gch_installed) && at_top && getRversion() >= "4.0.0") {
    .console_state$old_handlers <- globalCallingHandlers()
    # Observe only. Do NOT invoke the muffle restarts: the user must still see
    # their own warnings and messages in the console.
    globalCallingHandlers(
      warning = function(w) console_note_condition("warning", conditionMessage(w)),
      message = function(m) console_note_condition("message", conditionMessage(m))
    )
    .console_state$gch_installed <- TRUE
  }

  reg.finalizer(.console_state,
                function(e) tryCatch(console_sink_close(), error = function(x) NULL),
                onexit = TRUE)
  message("ClaudeR: console logging on. Your console commands now appear in the session log.")
  if (!ok_sink) {
    message("ClaudeR: could not capture printed output here; ",
            "commands and their values will still be logged.")
  }
  if (!isTRUE(.console_state$gch_installed)) {
    message("ClaudeR: warnings are logged from last.warning; message() output is not ",
            "captured when logging is started from the addin. Run ",
            "start_console_logging() in the console for full capture.")
  }
  # Our own startup messages must not show up as the user's first log entry.
  .console_state$pending <- NULL
  invisible(TRUE)
}

#' Stop logging the user's console activity
#'
#' @return Invisibly TRUE.
#' @export
stop_console_logging <- function() {
  at_top <- sys.nframe() == 1L
  if (!isTRUE(.console_state$active) &&
      !("clauder_console_log" %in% getTaskCallbackNames())) return(invisible(TRUE))
  tryCatch(removeTaskCallback("clauder_console_log"), error = function(e) NULL)
  console_sink_close()
  if (isTRUE(.console_state$gch_installed) && at_top) {
    # Drop ours, then put back whatever was registered before, so handlers
    # belonging to other packages survive. Only possible at bare top level;
    # from the addin the handlers stay installed but become no-ops because
    # console_note_condition() checks .console_state$active.
    globalCallingHandlers(NULL)
    old <- .console_state$old_handlers
    if (length(old)) do.call(globalCallingHandlers, old)
    .console_state$gch_installed <- FALSE
  }
  if (isTRUE(.console_state$old_error_set)) {
    options(error = .console_state$old_error)
    .console_state$old_error_set <- NULL
  }
  .console_state$active <- FALSE
  .console_state$pending <- NULL
  message("ClaudeR: console logging off.")
  invisible(TRUE)
}
