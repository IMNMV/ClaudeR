# --- Value Reconciliation ---
# The backbone of a manuscript audit: enumerate every number the document
# states, build a corpus of every number the code actually produced, and
# account for each one. Completeness at the data level, not the reading
# level -- an agent can misread a value while "reading carefully", but it
# cannot skip a row of a registry it is gated on.

# Normalize scientific-notation typography so "1.5 x 10^-3", "2.1 × 10^(−4)",
# and "3e-2" all tokenize identically. Unicode minus is folded to ASCII.
normalize_number_text <- function(line) {
  line <- gsub("\u2212", "-", line)
  gsub("\\s*[x\u00d7\u22c5\u00b7]\\s*10\\s*\\^?\\s*[({\\[]?\\s*([-+]?\\d+)(?:\\s*[)}\\]])?",
       "e\\1", line, perl = TRUE)
}

# Tokenize the numeric values in one line. Returns a data.frame with one row
# per token: raw text, numeric value, displayed precision (as a ulp), and
# flags for thresholds ("< .001") and percents.
extract_numbers_from_line <- function(line) {
  empty <- data.frame(raw = character(0), value = numeric(0), ulp = numeric(0),
                      is_threshold = logical(0), threshold_dir = character(0),
                      is_percent = logical(0), stringsAsFactors = FALSE)
  norm <- normalize_number_text(line)
  pattern <- paste0(
    "(?<![A-Za-z0-9_.])",              # not inside a word/identifier/decimal
    "([<>]\\s*)?",                     # optional threshold marker
    "(-?(?:\\d{1,3}(?:,\\d{3})+(?:\\.\\d+)?|\\d+\\.\\d+|\\.\\d+|\\d+))",
    "([eE][-+]?\\d+)?",                # optional exponent
    "(\\s?%)?",                        # optional percent
    "(?![A-Za-z0-9_])"                 # not running into a word
  )
  m <- gregexpr(pattern, norm, perl = TRUE)
  if (m[[1]][1] == -1) return(empty)

  toks <- regmatches(norm, m)[[1]]
  out <- lapply(toks, function(tok) {
    raw <- trimws(tok)
    dir <- if (grepl("^<", raw)) "<" else if (grepl("^>", raw)) ">" else ""
    is_pct <- grepl("%$", raw)
    core <- gsub("^[<>]\\s*|\\s?%$", "", raw)
    core <- gsub(",", "", core)

    mant <- sub("[eE].*$", "", core)
    exp_part <- if (grepl("[eE]", core)) {
      as.integer(sub("^.*[eE]", "", core))
    } else 0L
    n_dec <- if (grepl("\\.", mant)) nchar(sub("^-?\\d*\\.", "", mant)) else 0L

    value <- suppressWarnings(as.numeric(core))
    if (is.na(value)) return(NULL)
    data.frame(raw = raw, value = value,
               ulp = 10^(exp_part - n_dec),
               is_threshold = nzchar(dir), threshold_dir = dir,
               is_percent = is_pct, stringsAsFactors = FALSE)
  })
  out <- out[!vapply(out, is.null, logical(1))]
  if (length(out) == 0) return(empty)
  do.call(rbind, out)
}

# A bibliography line: contains a DOI/arXiv id, or looks like an APA entry
# (a parenthesized year followed later by a page range). Values on such lines
# are citation metadata (volumes, issues, pages, DOI fragments), not results.
is_reference_line <- function(line) {
  grepl("doi\\.org/|\\barXiv:", line, ignore.case = TRUE) ||
    grepl("\\((17|18|19|20)\\d\\d[a-z]?\\)\\..*\\d+-\\d+\\.?$", line, perl = TRUE)
}

# Extract all numbers from a character vector, with line numbers and context.
extract_numbers_impl <- function(lines, label = "text") {
  res <- lapply(seq_along(lines), function(i) {
    # Strip the structured-extractor cell markers ("[Table 2, row 5] ...")
    # before tokenizing: the table and row indices are our own metadata, not
    # values the document states.
    clean <- sub("^\\[Table \\d+, (row \\d+|header)\\] ", "", lines[i])
    d <- extract_numbers_from_line(clean)
    if (nrow(d) == 0) return(NULL)
    d$line <- i
    d$is_reference <- is_reference_line(lines[i])
    ctx <- trimws(lines[i])
    if (nchar(ctx) > 160) ctx <- paste0(substr(ctx, 1, 157), "...")
    d$context <- ctx
    d
  })
  res <- res[!vapply(res, is.null, logical(1))]
  if (length(res) == 0) {
    return(data.frame(raw = character(0), value = numeric(0), ulp = numeric(0),
                      is_threshold = logical(0), threshold_dir = character(0),
                      is_percent = logical(0), line = integer(0),
                      is_reference = logical(0),
                      context = character(0), source = character(0),
                      stringsAsFactors = FALSE))
  }
  out <- do.call(rbind, res)
  out$source <- label
  out
}

# Read any file as text lines, routing manuscripts through the structured
# extractor so table cells stay separated.
read_as_text_lines <- function(path) {
  ext <- tolower(tools::file_ext(path))
  if (ext %in% c("docx", "pdf")) extract_manuscript_text(path)
  else readLines(path, warn = FALSE)
}

# Does any corpus value match this document value at its displayed precision?
value_matches_corpus <- function(value, ulp, corpus_values) {
  tol <- ulp / 2 * (1 + 1e-9) + 1e-12
  any(abs(corpus_values - value) <= tol)
}

#' Reconcile every number in a document against source outputs
#'
#' Extracts every numeric token from a manuscript (or supplement) and checks
#' each against the corpus of numbers found in the given source files (logs,
#' generated tables, script output, CSVs). Matching respects the document's
#' displayed precision: a document value of `5038.5` matches a source value
#' of `5038.46`, and `0.967` matches `0.9668`. Thresholds like `< .001` are
#' satisfied by any smaller source value; percents are also checked against
#' their proportion form (flagged as scaled). Years (1900-2100, no decimals)
#' are skipped by default.
#'
#' The full per-value registry is assigned to `values_registry` in the global
#' environment so an audit can be gated on every row being accounted for.
#'
#' @param document Path to the manuscript (.docx, .pdf, or text; .docx tables
#'   are extracted cell-separated).
#' @param sources Character vector of files whose numbers form the corpus.
#' @param ignore_years Skip 4-digit integers in 1900-2100. Default TRUE.
#' @param max_unmatched_shown Cap on unmatched values printed in the summary
#'   (the registry always holds all of them). Default 100.
#' @return The summary report as a character string (invisibly); the
#'   `values_registry` data.frame is assigned to the global environment.
#' @export
reconcile_values <- function(document, sources, ignore_years = TRUE,
                             max_unmatched_shown = 100L) {
  document <- path.expand(document)
  if (!file.exists(document)) stop("Document not found: ", document, call. = FALSE)
  sources <- path.expand(sources)
  missing_src <- sources[!file.exists(sources)]
  if (length(missing_src) > 0) {
    stop("Source file(s) not found: ", paste(missing_src, collapse = ", "), call. = FALSE)
  }

  doc_nums <- extract_numbers_impl(read_as_text_lines(document), basename(document))

  corpus <- numeric(0)
  for (s in sources) {
    sn <- extract_numbers_impl(read_as_text_lines(s), basename(s))
    corpus <- c(corpus, sn$value, sn$value[sn$is_percent] / 100)
  }
  corpus <- unique(corpus)

  if (nrow(doc_nums) == 0) {
    return(invisible("No numeric values found in the document."))
  }

  status <- character(nrow(doc_nums))
  for (i in seq_len(nrow(doc_nums))) {
    v <- doc_nums$value[i]
    u <- doc_nums$ulp[i]
    if (isTRUE(doc_nums$is_reference[i])) {
      # Volumes, issues, pages, and DOI fragments on bibliography lines are
      # citation metadata; verify_references audits those, not the sweep.
      status[i] <- "reference_meta"
    } else if (ignore_years && !doc_nums$is_percent[i] && !doc_nums$is_threshold[i] &&
        u == 1 && v >= 1900 && v <= 2100 && v == floor(v)) {
      status[i] <- "year_skipped"
    } else if (doc_nums$is_threshold[i]) {
      ok <- if (doc_nums$threshold_dir[i] == "<") any(corpus < v + 1e-12)
            else any(corpus > v - 1e-12)
      status[i] <- if (ok) "threshold_ok" else "unmatched"
    } else if (value_matches_corpus(v, u, corpus)) {
      status[i] <- "matched"
    } else if (doc_nums$is_percent[i] &&
               value_matches_corpus(v / 100, u / 100, corpus)) {
      status[i] <- "matched_scaled"
    } else {
      status[i] <- "unmatched"
    }
  }

  registry <- data.frame(
    value_id = seq_len(nrow(doc_nums)),
    line = doc_nums$line,
    raw = doc_nums$raw,
    value = doc_nums$value,
    status = status,
    context = doc_nums$context,
    adjudicated = FALSE,
    note = "",
    stringsAsFactors = FALSE
  )
  assign("values_registry", registry, envir = .GlobalEnv)

  n <- nrow(registry)
  counts <- table(factor(registry$status,
                         levels = c("matched", "matched_scaled", "threshold_ok",
                                    "unmatched", "year_skipped", "reference_meta")))
  unmatched <- registry[registry$status == "unmatched", , drop = FALSE]
  shown <- utils::head(unmatched, max_unmatched_shown)

  report <- paste0(
    "=== VALUE RECONCILIATION ===\n",
    sprintf("Document: %s (%d numeric values)\n", basename(document), n),
    sprintf("Corpus: %d unique values from %d source file(s)\n",
            length(corpus), length(sources)),
    sprintf("matched: %d | matched_scaled: %d | threshold_ok: %d | unmatched: %d | year_skipped: %d | reference_meta: %d\n",
            counts["matched"], counts["matched_scaled"], counts["threshold_ok"],
            counts["unmatched"], counts["year_skipped"], counts["reference_meta"]),
    "\n'values_registry' has been assigned to the global environment.\n",
    if (nrow(unmatched) == 0) {
      "\nEvery non-year value is accounted for.\n"
    } else {
      paste0(
        sprintf("\nUNMATCHED VALUES (%d%s) -- each must be adjudicated:\n",
                nrow(unmatched),
                if (nrow(unmatched) > nrow(shown))
                  sprintf(", first %d shown", nrow(shown)) else ""),
        paste(sprintf("  [id %d, line %d] %s :: %s",
                      shown$value_id, shown$line, shown$raw, shown$context),
              collapse = "\n"),
        "\n\nFor each: recompute it, or mark why it cannot come from the sources",
        "\n(e.g. citation year, DOI fragment, versioning). Record verdicts with:",
        "\n  values_registry$adjudicated[values_registry$value_id == ID] <- TRUE",
        "\n  values_registry$note[values_registry$value_id == ID] <- \"reason\"\n"
      )
    }
  )
  cat(report)
  invisible(report)
}
