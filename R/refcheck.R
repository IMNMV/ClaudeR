# --- Cross-Reference Integrity ---
# The deterministic slice of "follow the internal references": inventory what
# a manuscript declares (tables, figures, theorems, appendices, numbered
# sections) against what it mentions, and flag references that point nowhere
# plus declared items never referenced. Every revision cycle manufactures
# these ("see Table 4" after Table 4 became Table 3), and no amount of
# careful prose reading reliably catches them.

# Expand "Tables 1-3", "Figures 2 and 4", "Eqs. 1, 3, and 7" into the label
# numbers they mention.
expand_ref_numbers <- function(tail_text) {
  tail_text <- gsub("\u2013|\u2014", "-", tail_text)
  # Keep only the leading run of numbers/letters joined by , and - &
  run <- regmatches(tail_text,
    regexpr("^\\s*([A-Z]?\\d+(?:\\.\\d+)*|[A-Z])(\\s*(,|and|&|-|to)\\s*([A-Z]?\\d+(?:\\.\\d+)*|[A-Z]))*",
            tail_text, perl = TRUE))
  if (length(run) == 0 || !nzchar(run)) return(character(0))
  # Range expansion for simple integer ranges ("1-3")
  parts <- strsplit(run, "\\s*(,|and|&|to)\\s*", perl = TRUE)[[1]]
  out <- character(0)
  for (p in parts) {
    p <- trimws(p)
    if (grepl("^\\d+\\s*-\\s*\\d+$", p)) {
      lo <- as.integer(sub("-.*$", "", p))
      hi <- as.integer(sub("^.*-", "", p))
      if (!is.na(lo) && !is.na(hi) && hi >= lo && hi - lo <= 50) {
        out <- c(out, as.character(lo:hi))
      }
    } else if (nzchar(p)) {
      out <- c(out, gsub("\\s", "", p))
    }
  }
  unique(out[nzchar(out)])
}

# Find declared items and mentions for one reference class. Declaration
# lines are excluded from the mention scan (a table's own caption is not a
# reference to it), and the id pattern is class-appropriate: numeric ids for
# tables/figures/theorems, single letters for appendices. Mixing them lets
# "Table 1 and Figure 2" wrongly swallow the F of "Figure".
scan_ref_class <- function(lines, class_name, declare_patterns, mention_labels,
                           id_pattern = "\\d+(?:\\.\\d+)*",
                           marker_patterns = character(0)) {
  scan_decl <- function(pats) {
    ids <- character(0); at <- integer(0)
    for (pat in pats) {
      mm <- regexec(pat, lines, perl = TRUE)
      for (i in seq_along(mm)) {
        if (mm[[i]][1] == -1) next
        grp <- regmatches(lines[i], mm[i])[[1]]
        if (length(grp) >= 2 && nzchar(grp[2])) {
          ids <- c(ids, grp[2]); at <- c(at, i)
        }
      }
    }
    list(ids = unique(ids), lines = unique(at))
  }
  cap <- scan_decl(declare_patterns)
  mark <- scan_decl(marker_patterns)
  declared <- unique(c(cap$ids, mark$ids))
  declared_caption <- cap$ids
  decl_lines <- unique(c(cap$lines, mark$lines))

  labels_alt <- paste(mention_labels, collapse = "|")
  mention_pat <- paste0("(?i)\\b(", labels_alt, ")\\.?\\s+(", id_pattern,
                        "(?:\\s*(?:,|and|&|-|to|\u2013)\\s*", id_pattern, ")*)")
  mentions <- data.frame(line = integer(0), id = character(0),
                         stringsAsFactors = FALSE)
  for (i in seq_along(lines)) {
    if (i %in% decl_lines) next
    mm <- gregexpr(mention_pat, lines[i], perl = TRUE)
    if (mm[[1]][1] == -1) next
    for (tok in regmatches(lines[i], mm)[[1]]) {
      tail_text <- sub(paste0("(?i)^\\b(", labels_alt, ")\\.?\\s+"), "",
                       tok, perl = TRUE)
      ids <- expand_ref_numbers(tail_text)
      if (length(ids) > 0) {
        mentions <- rbind(mentions, data.frame(line = i, id = ids,
                                               stringsAsFactors = FALSE))
      }
    }
  }
  list(class = class_name, declared = declared,
       declared_caption = declared_caption, mentions = mentions)
}

#' Check a manuscript's internal cross-references
#'
#' Inventories the tables, figures, theorem-like environments, appendices,
#' and numbered equations a document declares, then checks every in-text
#' mention ("see Table 4", "Figures 2 and 3", "Theorem 1") against that
#' inventory. Flags dangling references (mentioned but not declared) and
#' orphans (declared tables/figures never referenced in the text).
#'
#' Word auto-numbering does not always survive text extraction, so any class
#' with zero detectable declarations is reported as unverifiable rather than
#' flooding the report with false dangling flags.
#'
#' @param document Path to the manuscript (.docx, .pdf, or plain text).
#' @return The report as a character string (invisibly); a
#'   `crossref_registry` data.frame is assigned to the global environment.
#' @export
check_cross_references <- function(document) {
  document <- path.expand(document)
  if (!file.exists(document)) stop("Document not found: ", document, call. = FALSE)
  lines <- read_as_text_lines(document)

  classes <- list(
    scan_ref_class(lines, "Table",
      c("^Table (S?\\d+)[.:]"),
      c("Table", "Tables", "Tab"),
      id_pattern = "S?\\d+(?:\\.\\d+)*",
      marker_patterns = c("^\\[Table (\\d+),")),
    scan_ref_class(lines, "Figure",
      c("^Figure (S?\\d+)[.:]", "^Fig\\.? (S?\\d+)[.:]"),
      c("Figure", "Figures", "Fig", "Figs"),
      id_pattern = "S?\\d+(?:\\.\\d+)*"),
    scan_ref_class(lines, "Equation",
      c("^Equation (\\d+)[.:]", "^\\((\\d+)\\)\\s*$"),
      c("Equation", "Equations", "Eq", "Eqs")),
    scan_ref_class(lines, "Theorem",
      c("^#*\\s*Theorem (\\d+)"), c("Theorem", "Theorems", "Thm")),
    scan_ref_class(lines, "Lemma",
      c("^#*\\s*Lemma (\\d+)"), c("Lemma", "Lemmas", "Lemmata")),
    scan_ref_class(lines, "Proposition",
      c("^#*\\s*Proposition (\\d+)"), c("Proposition", "Propositions", "Prop")),
    scan_ref_class(lines, "Appendix",
      c("^#*\\s*Appendix ([A-Z])\\b", "^\\[Appendix ([A-Z])\\]"),
      c("Appendix", "Appendices"), id_pattern = "[A-Z](?![A-Za-z])"),
    scan_ref_class(lines, "Section",
      c("^#+\\s*(\\d+(?:\\.\\d+)*)[.:\\s]"),
      c("Section", "Sections", "Sec"))
  )

  rows <- list()
  report_parts <- character(0)
  for (cl in classes) {
    n_decl <- length(cl$declared)
    n_ment <- length(unique(cl$mentions$id))
    if (n_decl == 0 && nrow(cl$mentions) == 0) next

    if (n_decl == 0) {
      report_parts <- c(report_parts, sprintf(
        "%s: %d mention(s) but no detectable declarations -- numbering may be auto-generated in Word; verify this class manually.",
        cl$class, n_ment))
      next
    }

    dangling <- cl$mentions[!(cl$mentions$id %in% cl$declared), , drop = FALSE]
    # Orphan reporting uses the author-facing numbering. When caption-style
    # declarations exist (e.g. "Table S1."), the extractor's own [Table k]
    # markers carry a parallel numbering that the prose never cites, and
    # flagging those as never-referenced is noise, not signal.
    orphan_base <- if (length(cl$declared_caption) > 0) cl$declared_caption else cl$declared
    orphans <- if (cl$class %in% c("Table", "Figure")) {
      setdiff(orphan_base, unique(cl$mentions$id))
    } else character(0)

    report_parts <- c(report_parts, sprintf(
      "%s: %d declared (%s) | %d unique mentioned%s%s",
      cl$class, n_decl, paste(sort(cl$declared), collapse = ", "), n_ment,
      if (nrow(dangling) > 0) {
        paste0("\n  !! DANGLING: ",
               paste(sprintf("%s %s (line %d)", cl$class, dangling$id, dangling$line),
                     collapse = "; "))
      } else "",
      if (length(orphans) > 0) {
        paste0("\n  !! NEVER REFERENCED: ", cl$class, " ",
               paste(sort(orphans), collapse = ", "))
      } else ""
    ))

    if (nrow(dangling) > 0) {
      rows[[length(rows) + 1]] <- data.frame(
        class = cl$class, id = dangling$id, line = dangling$line,
        issue = "dangling", stringsAsFactors = FALSE)
    }
    if (length(orphans) > 0) {
      rows[[length(rows) + 1]] <- data.frame(
        class = cl$class, id = orphans, line = NA_integer_,
        issue = "never_referenced", stringsAsFactors = FALSE)
    }
  }

  registry <- if (length(rows) > 0) do.call(rbind, rows) else {
    data.frame(class = character(0), id = character(0), line = integer(0),
               issue = character(0), stringsAsFactors = FALSE)
  }
  assign("crossref_registry", registry, envir = .GlobalEnv)

  report <- paste0(
    "=== CROSS-REFERENCE CHECK ===\n",
    sprintf("Document: %s\n\n", basename(document)),
    paste(report_parts, collapse = "\n"),
    sprintf("\n\n%d issue(s) found. 'crossref_registry' assigned to the global environment.\n",
            nrow(registry))
  )
  cat(report)
  invisible(report)
}
