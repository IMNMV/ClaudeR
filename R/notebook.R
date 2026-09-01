# --- Lab Notebook Generator ---
# Transforms a ClaudeR session log into a narrated Quarto document. The log
# stores only code; outputs and plots are regenerated when the .qmd renders,
# which also proves the session is reproducible end-to-end.

#' Export a ClaudeR session log as a Quarto lab notebook
#'
#' Parses a session log and writes a `.qmd` where each executed block becomes
#' an executable chunk, with the timestamp and agent recorded above it and a
#' `<!-- TODO: narration -->` marker for prose. Error blocks are included as
#' non-evaluated chunks with the error message, preserving the record of what
#' was tried. Rendering the notebook re-runs the session code, regenerating
#' outputs and plots.
#'
#' @param log_path Path to the ClaudeR session log. If NULL, uses the current
#'   session's log file from settings.
#' @param output_path Path for the `.qmd`. Default: log path with a
#'   `_notebook.qmd` suffix.
#' @param title Notebook title. Default is derived from the log filename.
#' @param include_errors If TRUE (default), errored blocks are kept as
#'   non-evaluated chunks so the notebook records dead ends, not just wins.
#' @return The output path, invisibly.
#' @export
export_log_as_notebook <- function(log_path = NULL, output_path = NULL,
                                   title = NULL, include_errors = TRUE) {
  if (is.null(log_path)) {
    settings <- load_claude_settings()
    if (!isTRUE(settings$log_to_file) || is.null(settings$log_file_path)) {
      stop("Logging is not enabled. Pass a log_path explicitly.", call. = FALSE)
    }
    log_path <- settings$log_file_path
  }
  log_path <- path.expand(log_path)
  if (!file.exists(log_path)) stop("Log file not found: ", log_path, call. = FALSE)

  if (is.null(output_path)) {
    output_path <- sub("\\.R$", "_notebook.qmd", log_path)
    if (output_path == log_path) output_path <- paste0(log_path, "_notebook.qmd")
  }
  if (is.null(title)) {
    title <- paste("Lab Notebook:", sub("\\.R$", "", basename(log_path)))
  }

  lines <- readLines(log_path, warn = FALSE)

  # Session metadata from the reproducibility header, if present
  header_end <- 0L
  session_date <- ""
  session_wd <- ""
  hdr <- grep("^# Date: ", lines)
  if (length(hdr) > 0) session_date <- sub("^# Date: ", "", lines[hdr[1]])
  wd <- grep("^# Working Directory: ", lines)
  if (length(wd) > 0) session_wd <- sub("^# Working Directory: ", "", lines[wd[1]])

  block_starts <- grep("^# --- \\[", lines)
  if (length(block_starts) == 0) {
    stop("No code blocks found in log file.", call. = FALSE)
  }
  block_ends <- c(block_starts[-1] - 1L, length(lines))

  out <- c(
    "---",
    paste0("title: \"", gsub("\"", "'", title), "\""),
    paste0("date: \"", format(Sys.Date()), "\""),
    "format:",
    "  html:",
    "    toc: true",
    "    code-fold: false",
    "    embed-resources: true",
    "execute:",
    "  error: true",
    "  warning: true",
    "---",
    "",
    "## Session",
    "",
    paste0("- Source log: `", basename(log_path), "`"),
    if (nzchar(session_date)) paste0("- Session date: ", session_date) else NULL,
    if (nzchar(session_wd)) paste0("- Working directory: `", session_wd, "`") else NULL,
    "",
    "<!-- TODO: narration -- one paragraph on what this session set out to do -->",
    ""
  )

  step <- 0L
  for (i in seq_along(block_starts)) {
    block <- lines[block_starts[i]:block_ends[i]]

    ts <- sub("^# --- \\[(.*)\\] ---$", "\\1", block[1])
    agent_line <- if (length(block) >= 2) block[2] else ""
    agent <- sub("^# Code executed by ([^ ]+).*$", "\\1", agent_line)
    is_error <- grepl("(ERROR)", agent_line, fixed = TRUE)
    err_msgs <- sub("^# Error: ", "", block[grepl("^# Error: ", block)])

    code_lines <- block[!grepl("^# --- \\[|^# Code executed by |^# Run by |^# Error: |^#> ", block)]
    while (length(code_lines) > 0 && trimws(code_lines[length(code_lines)]) == "") {
      code_lines <- code_lines[-length(code_lines)]
    }
    while (length(code_lines) > 0 && trimws(code_lines[1]) == "") {
      code_lines <- code_lines[-1]
    }
    if (length(code_lines) == 0) next

    if (is_error && !isTRUE(include_errors)) next

    step <- step + 1L
    out <- c(out,
      paste0("## Step ", step,
             if (is_error) " (errored)" else "",
             " {#step-", step, "}"),
      "",
      paste0("*", ts, " -- ", agent, "*"),
      "",
      "<!-- TODO: narration -- what was tried here and why -->",
      ""
    )

    if (is_error) {
      out <- c(out,
        "```{r}",
        "#| eval: false",
        code_lines,
        "```",
        "",
        paste0("> This block errored during the session: `",
               gsub("`", "'", paste(err_msgs, collapse = "; ")), "`"),
        ""
      )
    } else {
      out <- c(out,
        "```{r}",
        code_lines,
        "```",
        ""
      )
    }
  }

  out <- c(out,
    "## Wrap-up",
    "",
    "<!-- TODO: narration -- what was concluded, and what remains open -->",
    ""
  )

  writeLines(out, output_path)
  message(sprintf("Notebook written: %s (%d steps%s)",
                  output_path, step,
                  if (isTRUE(include_errors)) ", errors preserved" else ""))
  invisible(output_path)
}
