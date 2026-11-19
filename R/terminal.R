# Starting and stopping the server from the R console, with no addin window.
# This is the way in for terminal R (a cluster, an ssh login, tmux, Rscript),
# and it works in RStudio and Positron too, where it leaves the console free.

# TRUE inside RStudio or Positron, where the editor tools have something to
# reach and plots have a pane to land in.
has_editor <- function() {
  requireNamespace("rstudioapi", quietly = TRUE) &&
    isTRUE(tryCatch(rstudioapi::isAvailable(), error = function(e) FALSE))
}

# Show coordination messages in the console and the session log every two
# seconds, the way the addin does while its window is open. Each start gets
# its own number, so a timer left over from an earlier start ends by itself.
start_coord_echo <- function() {
  gen <- (if (is.null(.claude_server_env$echo_gen)) 0L else .claude_server_env$echo_gen) + 1L
  .claude_server_env$echo_gen <- gen
  tick <- function() {
    if (!isTRUE(.claude_server_env$running) ||
        !identical(.claude_server_env$echo_gen, gen)) {
      return(invisible(NULL))
    }
    try(coord_echo_once(), silent = TRUE)
    later::later(tick, 2)
  }
  later::later(tick, 2)
  invisible(NULL)
}

#' Start the ClaudeR server from the R console
#'
#' Does what the addin's **Start Server** button does, with no addin window
#' and no RStudio needed. Run it in plain terminal R (a cluster, an ssh
#' login, a tmux pane) or from `Rscript`, and agents connect to the session
#' the same way they connect to one started from the addin.
#'
#' It also works inside RStudio and Positron. There the console stays free
#' while agents work, which it does not while the addin window is open.
#'
#' Outside RStudio and Positron two things differ. The editor tools (reading
#' and editing the open document) are left out, since there is no editor.
#' And when R has no screen to draw on, plots go to a hidden image device so
#' the agent still sees them.
#'
#' Agents are served whenever R is idle. While your own code is running, an
#' agent's request waits until it finishes.
#'
#' @param session_name Name agents use to find this session. Each running
#'   session needs its own.
#' @param port Port to listen on. Each running session needs its own.
#' @param block `TRUE` keeps R serving agents until you interrupt it
#'   (Ctrl+C). Use it with `Rscript`, in a batch job, or in a tmux pane you
#'   leave alone. `FALSE` returns straight away and agents are served while
#'   the prompt is idle. The default is `FALSE` at an interactive prompt and
#'   `TRUE` otherwise.
#' @param fresh_start `TRUE` clears the agent history and execution count
#'   first and moves the session's old message board to an archive folder,
#'   so agents start on an empty board, like the addin's "Fresh start on
#'   restart" box. Nothing is deleted.
#' @param require_token `TRUE` rejects any request without this session's
#'   token. The default is the setting saved from the addin's Advanced panel.
#' @return Invisibly, a list with the session name, the port, the path of
#'   the session log (`NULL` when logging is off) and the folder the old
#'   message board was moved to (`NULL` unless a fresh start moved one).
#' @seealso [stop_server()] to stop it, [claudeAddin()] for the addin window.
#' @examples
#' \dontrun{
#' # At an R prompt: returns at once and the prompt stays yours
#' ClaudeR::start_server("analysis")
#'
#' # In a batch job or a tmux pane: serves until interrupted
#' # Rscript -e 'ClaudeR::start_server("fit", port = 8790, block = TRUE)'
#' }
#' @export
start_server <- function(session_name = "default", port = 8787,
                         block = !interactive(), fresh_start = FALSE,
                         require_token = NULL) {
  if (isTRUE(.claude_server_env$running)) {
    stop(sprintf(
      "ClaudeR is already running in this session as '%s' on port %s. Run stop_server() first to start it again.",
      .claude_server_env$session_name, .claude_server_env$port), call. = FALSE)
  }

  settings <- load_claude_settings()
  .claude_server_env$settings <- settings
  if (is.null(require_token)) require_token <- isTRUE(settings$require_token)

  .claude_server_env$headless <- !has_editor()
  started <- tryCatch(
    server_start(session_name, port, require_token = require_token,
                 fresh_start = fresh_start),
    error = function(e) {
      # Leave nothing half started behind a failed call.
      if (isTRUE(.claude_server_env$running)) try(server_stop(), silent = TRUE)
      .claude_server_env$headless <- NULL
      stop(conditionMessage(e), call. = FALSE)
    }
  )
  if (isTRUE(.claude_server_env$headless)) use_offscreen_device()
  start_coord_echo()

  message(sprintf(
    "ClaudeR: session '%s' is running on http://127.0.0.1:%s. Stop it with ClaudeR::stop_server().",
    started$session_name, started$port))

  if (isTRUE(block)) {
    message("Serving agents until interrupted (Ctrl+C).")
    on.exit(if (isTRUE(.claude_server_env$running)) server_stop(), add = TRUE)
    while (isTRUE(.claude_server_env$running)) httpuv::service(250)
  }
  invisible(started)
}

#' Stop the ClaudeR server
#'
#' Stops the server in this R session, whether it was started with
#' [start_server()] or with the addin's Start Server button. Your R
#' environment is left as it is.
#'
#' @return Invisibly, `TRUE` if a server was stopped and `FALSE` if none was
#'   running.
#' @seealso [start_server()]
#' @export
stop_server <- function() {
  if (!isTRUE(.claude_server_env$running)) {
    message("ClaudeR is not running in this session.")
    return(invisible(FALSE))
  }
  name <- .claude_server_env$session_name
  server_stop()
  message(sprintf("ClaudeR: session '%s' stopped.", name))
  invisible(TRUE)
}
