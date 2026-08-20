# --- Response to Reviewers ---
# Helpers behind the reviewer-response protocol. The protocol builds a
# point-by-point registry. This file turns that registry into the response
# letter every journal expects.

#' Print the response-to-reviewers protocol
#'
#' Walks an agent through a revise-and-resubmit: parse the decision letter
#' into a point-by-point registry, locate each point in the manuscript,
#' answer data questions with real computation in the session, draft
#' responses, and export the letter plus an annotated manuscript.
#'
#' @return The prompt text (invisibly), printed to the console.
#' @export
reviewer_response_prompt <- function() {
  prompt_path <- system.file("prompts", "reviewer_response.md", package = "ClaudeR")
  if (!nzchar(prompt_path) || !file.exists(prompt_path)) {
    stop("Reviewer response prompt template not found. Is ClaudeR installed correctly?")
  }
  txt <- paste(readLines(prompt_path, warn = FALSE), collapse = "\n")
  cat(txt, "\n")
  invisible(txt)
}

#' Export a point-by-point response letter from a response registry
#'
#' Formats the registry built by the reviewer-response protocol into a
#' response letter, grouped by reviewer, with each point quoted and answered
#' beneath it. Writes markdown, and also a .docx when pandoc is available.
#'
#' @param registry A data.frame with at least the columns `point_id`,
#'   `reviewer`, `verbatim`, and `response`.
#' @param output_path Path for the markdown letter. Default
#'   `"response_letter.md"`.
#' @param title Letter heading. Default "Response to Reviewers".
#' @return The markdown path (invisibly). The .docx path, when built, is
#'   the same with a .docx extension.
#' @export
export_response_letter <- function(registry, output_path = "response_letter.md",
                                   title = "Response to Reviewers") {
  needed <- c("point_id", "reviewer", "verbatim", "response")
  missing_cols <- setdiff(needed, names(registry))
  if (length(missing_cols) > 0) {
    stop("Registry is missing columns: ", paste(missing_cols, collapse = ", "),
         call. = FALSE)
  }
  if (nrow(registry) == 0) stop("Registry is empty.", call. = FALSE)
  undrafted <- !nzchar(trimws(registry$response))
  if (any(undrafted)) {
    stop("These points have no response yet: ",
         paste(registry$point_id[undrafted], collapse = ", "), call. = FALSE)
  }

  out <- c(paste0("# ", title), "",
           paste0("*", format(Sys.Date(), "%B %d, %Y"), "*"), "",
           "We thank the editor and reviewers for their careful reading and",
           "constructive comments. Point-by-point responses follow. Reviewer",
           "comments appear in italics.", "")

  for (rev_name in unique(registry$reviewer)) {
    out <- c(out, paste0("## ", rev_name), "")
    block <- registry[registry$reviewer == rev_name, , drop = FALSE]
    for (i in seq_len(nrow(block))) {
      out <- c(out,
        paste0("**", block$point_id[i], ".** *", trimws(block$verbatim[i]), "*"),
        "",
        trimws(block$response[i]),
        "")
    }
  }

  writeLines(out, output_path)
  built <- output_path

  if (nzchar(Sys.which("pandoc"))) {
    docx_path <- sub("\\.md$", ".docx", output_path)
    if (identical(docx_path, output_path)) docx_path <- paste0(output_path, ".docx")
    ok <- tryCatch({
      system2("pandoc", c(shQuote(output_path), "-o", shQuote(docx_path)),
              stdout = FALSE, stderr = FALSE)
      file.exists(docx_path)
    }, error = function(e) FALSE)
    if (isTRUE(ok)) built <- c(built, docx_path)
  }

  message("Response letter written: ", paste(built, collapse = " and "))
  invisible(output_path)
}
