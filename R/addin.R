#' Claude RStudio Connection Addin (deprecated)
#'
#' Deprecated. Use [claudeAddin()] instead.
#'
#' This used to be a second, independent implementation of the addin server.
#' It was never wired to the RStudio Addins menu (`inst/rstudio/addins.dcf`
#' binds `claudeAddin`) and the README never referenced it, but it remained
#' exported — so calling it started a server that had drifted badly out of
#' sync with the real one: no `Origin` block, no auth token, and no support
#' for async jobs, job cancellation, or viewer capture. Tools would silently
#' fail against it.
#'
#' It is now a thin shim that forwards to [claudeAddin()], so existing calls
#' keep working and route through the maintained, authenticated server.
#'
#' @param port Ignored, and kept only so old calls do not error. Set the port
#'   in the addin's Session panel instead.
#' @return See [claudeAddin()].
#' @seealso [claudeAddin()]
#' @export
claude_rstudio_addin <- function(port = 8787) {
  if (!missing(port)) {
    warning(
      "claude_rstudio_addin(port = ) is deprecated and the port argument is ",
      "ignored. Use claudeAddin() and set the port in the Session panel.",
      call. = FALSE
    )
  } else {
    warning(
      "claude_rstudio_addin() is deprecated. Use claudeAddin() instead.",
      call. = FALSE
    )
  }
  claudeAddin()
}
