# --- Systematic Review Screening ---
# Turns the annotation runner into a PRISMA-conformant screening pipeline.
# Records are screened row by row against prespecified criteria. Running the
# same file through two different model families gives two independent
# screeners. screening_report() computes the agreement statistics and the
# PRISMA flow counts, and isolates the conflicts a human must adjudicate.

# Cohen's kappa from two label vectors.
cohens_kappa <- function(a, b) {
  stopifnot(length(a) == length(b))
  a <- as.character(a)
  b <- as.character(b)
  levs <- sort(unique(c(a, b)))
  tab <- table(factor(a, levels = levs), factor(b, levels = levs))
  n <- sum(tab)
  if (n == 0) return(NA_real_)
  po <- sum(diag(tab)) / n
  pe <- sum(rowSums(tab) * colSums(tab)) / n^2
  if (pe >= 1) return(1)
  (po - pe) / (1 - pe)
}

read_screened <- function(path, include_field, reason_field) {
  d <- utils::read.csv(path, stringsAsFactors = FALSE)
  if (!include_field %in% names(d)) {
    stop("Column '", include_field, "' not found in ", path, call. = FALSE)
  }
  if (!reason_field %in% names(d)) d[[reason_field]] <- ""
  d
}

#' Summarize screening passes: PRISMA counts, agreement, conflicts
#'
#' Reads one or two screened copies of a records file (the `_annotating.csv`
#' outputs of `run_annotation_job`) and reports the numbers a systematic
#' review needs. With one pass: decision counts and exclusion reasons. With
#' two passes from different models: percent agreement, Cohen's kappa, and
#' the conflict set, which is the only part a human must read.
#'
#' The conflicts are assigned to `screening_conflicts` in the global
#' environment. PRISMA counts treat conflicting records as pending until
#' adjudicated.
#'
#' @param pass_a Path to the first screened CSV.
#' @param pass_b Optional path to a second screened CSV from a different
#'   model. Must have the same rows in the same order.
#' @param include_field Column holding the screening decision. Default
#'   `"include"`.
#' @param reason_field Column holding the exclusion reason. Default
#'   `"reason"`.
#' @return Invisibly, a list with counts, kappa, and conflicts. Prints the
#'   report.
#' @export
screening_report <- function(pass_a, pass_b = NULL,
                             include_field = "include",
                             reason_field = "reason") {
  a <- read_screened(path.expand(pass_a), include_field, reason_field)
  n <- nrow(a)
  dec_a <- trimws(tolower(as.character(a[[include_field]])))

  out <- list(n_records = n)
  report <- sprintf("=== SCREENING REPORT ===\nRecords screened: %d\n", n)

  if (is.null(pass_b)) {
    counts <- table(dec_a)
    out$counts <- counts
    reasons <- table(trimws(a[[reason_field]][dec_a == "exclude"]))
    reasons <- reasons[nzchar(names(reasons))]
    out$exclusion_reasons <- reasons
    report <- paste0(report,
      "Decisions: ", paste(sprintf("%s = %d", names(counts), counts), collapse = ", "), "\n",
      if (length(reasons) > 0) {
        paste0("Exclusion reasons:\n",
               paste(sprintf("  %s: %d", names(reasons), reasons), collapse = "\n"), "\n")
      } else "",
      "\nPRISMA: records screened = ", n,
      ", excluded = ", sum(dec_a == "exclude"),
      ", retained = ", sum(dec_a == "include"),
      if (any(dec_a == "maybe")) paste0(", flagged maybe = ", sum(dec_a == "maybe")) else "",
      "\nSingle-pass screening. For a defensible review, run a second pass",
      "\nwith a different model family and report agreement.\n")
  } else {
    b <- read_screened(path.expand(pass_b), include_field, reason_field)
    if (nrow(b) != n) {
      stop("Pass files have different row counts (", n, " vs ", nrow(b),
           "). They must screen the same records in the same order.", call. = FALSE)
    }
    dec_b <- trimws(tolower(as.character(b[[include_field]])))

    agree <- dec_a == dec_b
    pct <- 100 * mean(agree)
    kap <- cohens_kappa(dec_a, dec_b)

    conflicts <- data.frame(
      row = which(!agree),
      decision_a = dec_a[!agree],
      reason_a = trimws(a[[reason_field]][!agree]),
      decision_b = dec_b[!agree],
      reason_b = trimws(b[[reason_field]][!agree]),
      stringsAsFactors = FALSE
    )
    # Carry identifying columns if present so humans can find the records
    for (id_col in intersect(c("title", "id", "doi", "row_id"), names(a))) {
      conflicts[[id_col]] <- a[[id_col]][!agree]
    }
    assign("screening_conflicts", conflicts, envir = .GlobalEnv)

    both_exclude <- sum(dec_a == "exclude" & agree)
    both_include <- sum(dec_a == "include" & agree)
    out$percent_agreement <- pct
    out$kappa <- kap
    out$conflicts <- conflicts

    report <- paste0(report,
      sprintf("Two independent screening passes.\nAgreement: %.1f%% | Cohen's kappa = %.3f\n", pct, kap),
      sprintf("Agreed exclude = %d | agreed include = %d | conflicts = %d\n",
              both_exclude, both_include, nrow(conflicts)),
      "\nPRISMA (pending adjudication of conflicts):\n",
      sprintf("  records screened = %d\n  excluded (both screeners) = %d\n", n, both_exclude),
      sprintf("  retained (both screeners) = %d\n  conflicts for human adjudication = %d\n",
              both_include, nrow(conflicts)),
      "\n'screening_conflicts' has been assigned to the global environment.",
      "\nA human resolves only those rows. Report the kappa and the",
      "\nadjudication procedure in your methods section.\n")
  }

  cat(report)
  invisible(out)
}

#' Print the systematic-review screening protocol
#'
#' The protocol walks an agent through PRISMA-conformant title and abstract
#' screening: build the criteria schema, run two independent passes with
#' different model families, compute agreement, and hand only the conflicts
#' to the human.
#'
#' @return The prompt text (invisibly), printed to the console.
#' @export
screening_prompt <- function() {
  prompt_path <- system.file("prompts", "screening.md", package = "ClaudeR")
  if (!nzchar(prompt_path) || !file.exists(prompt_path)) {
    stop("Screening prompt template not found. Is ClaudeR installed correctly?")
  }
  txt <- paste(readLines(prompt_path, warn = FALSE), collapse = "\n")
  cat(txt, "\n")
  invisible(txt)
}
