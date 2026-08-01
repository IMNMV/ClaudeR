# --- Codebook / Reproducibility README Generator ---
# Scans a project's scripts for packages, data inputs, and saved outputs,
# reads each data file, and emits the variable-level codebook that OSF and
# most journals require for data sharing.

# One codebook section (markdown) for a single data frame.
codebook_for_df <- function(df, name) {
  rows <- vapply(names(df), function(v) {
    col <- df[[v]]
    cls <- paste(class(col), collapse = "/")
    n_miss <- sum(is.na(col))
    pct <- if (nrow(df) > 0) round(100 * n_miss / nrow(df), 1) else 0
    summ <- if (is.numeric(col)) {
      rng <- suppressWarnings(range(col, na.rm = TRUE))
      if (all(is.finite(rng))) {
        sprintf("range %s to %s, median %s",
                signif(rng[1], 4), signif(rng[2], 4),
                signif(stats::median(col, na.rm = TRUE), 4))
      } else "all missing"
    } else if (is.logical(col)) {
      sprintf("%d TRUE / %d FALSE", sum(col, na.rm = TRUE), sum(!col, na.rm = TRUE))
    } else {
      lv <- sort(table(as.character(col)), decreasing = TRUE)
      shown <- utils::head(names(lv), 5)
      extra <- length(lv) - length(shown)
      paste0(length(lv), " unique: ",
             paste(shown, collapse = ", "),
             if (extra > 0) sprintf(" (+%d more)", extra) else "")
    }
    # Escape pipes so values cannot break the markdown table
    summ <- gsub("|", "/", summ, fixed = TRUE)
    sprintf("| %s | %s | %d | %d (%.1f%%) | %s |", v, cls, length(col), n_miss, pct, summ)
  }, character(1))

  c(
    paste0("### ", name),
    "",
    sprintf("%d rows x %d columns", nrow(df), ncol(df)),
    "",
    "| variable | class | n | missing | summary |",
    "|---|---|---|---|---|",
    rows,
    ""
  )
}

# Try to read a data file into a data frame; NULL if unreadable/unsupported.
read_data_file <- function(path) {
  ext <- tolower(tools::file_ext(path))
  tryCatch({
    if (ext %in% c("csv", "txt")) utils::read.csv(path, stringsAsFactors = FALSE)
    else if (ext == "tsv") utils::read.delim(path, stringsAsFactors = FALSE)
    else if (ext == "rds") { x <- readRDS(path); if (is.data.frame(x)) x else NULL }
    else NULL
  }, error = function(e) NULL)
}

#' Generate a codebook and reproducibility README for a project
#'
#' Scans the project's scripts (.R, .Rmd, .qmd) for `library()`/`require()`
#' calls, data-read sites, and saved outputs; reads each discovered data file
#' (.csv/.tsv/.txt/.rds); and writes a markdown document with a package list
#' (including installed versions), a script inventory, per-file variable
#' codebooks (name, class, n, missingness, summary), and the outputs the
#' scripts produce. This is the "codebook of variable definitions" that OSF
#' and many journals require for shared data.
#'
#' @param project_dir Project root to scan. Default `"."`.
#' @param data_files Optional character vector of data files to document.
#'   When supplied, these are used instead of (not in addition to) scanning
#'   scripts for read sites.
#' @param output_path Where to write the markdown. Default
#'   `file.path(project_dir, "CODEBOOK.md")`.
#' @param max_files Maximum data files to read (default 20).
#' @return The output path, invisibly.
#' @export
generate_codebook <- function(project_dir = ".", data_files = NULL,
                              output_path = NULL, max_files = 20L) {
  project_dir <- normalizePath(path.expand(project_dir), mustWork = TRUE, winslash = "/")
  if (is.null(output_path)) output_path <- file.path(project_dir, "CODEBOOK.md")

  scripts <- list.files(project_dir, pattern = "\\.(R|Rmd|qmd)$",
                        recursive = TRUE, full.names = TRUE, ignore.case = TRUE)
  scripts <- scripts[!grepl("/(renv|packrat|\\.git|clauder_lab)/", scripts)]

  pkgs <- character(0)
  reads <- character(0)
  writes <- character(0)
  read_pattern <- "(read\\.csv|read_csv|read\\.delim|read_tsv|readRDS|read_rds|load|read_excel|read_xlsx|fread|read_sav|read_dta)\\s*\\(\\s*['\"]([^'\"]+)['\"]"
  write_pattern <- "(write\\.csv|write_csv|saveRDS|write_rds|ggsave|save|writeLines|write\\.table)\\s*\\(\\s*(?:[^,)]*,\\s*)?(?:file(?:name)?\\s*=\\s*)?['\"]([^'\"]+)['\"]"

  for (s in scripts) {
    src <- tryCatch(readLines(s, warn = FALSE), error = function(e) character(0))
    src <- src[!grepl("^\\s*#", src)]
    txt <- paste(src, collapse = "\n")

    pk <- regmatches(txt, gregexpr("(library|require)\\s*\\(\\s*['\"]?([A-Za-z][A-Za-z0-9.]*)", txt))[[1]]
    pkgs <- c(pkgs, sub("(library|require)\\s*\\(\\s*['\"]?", "", pk))

    for (m in regmatches(txt, gregexpr(read_pattern, txt, perl = TRUE))[[1]]) {
      reads <- c(reads, sub(read_pattern, "\\2", m, perl = TRUE))
    }
    for (m in regmatches(txt, gregexpr(write_pattern, txt, perl = TRUE))[[1]]) {
      writes <- c(writes, sub(write_pattern, "\\2", m, perl = TRUE))
    }
  }
  pkgs <- sort(unique(pkgs))
  reads <- unique(reads)
  writes <- unique(writes)

  # Resolve the data files to document
  if (is.null(data_files)) {
    candidates <- vapply(reads, function(p) {
      if (file.exists(p)) return(p)
      alt <- file.path(project_dir, p)
      if (file.exists(alt)) alt else NA_character_
    }, character(1))
    data_files <- unname(candidates[!is.na(candidates)])
  } else {
    data_files <- path.expand(data_files)
    data_files <- data_files[file.exists(data_files)]
  }
  dropped <- length(data_files) - min(length(data_files), max_files)
  data_files <- utils::head(data_files, max_files)

  pkg_lines <- if (length(pkgs) > 0) {
    vapply(pkgs, function(p) {
      ver <- tryCatch(as.character(utils::packageVersion(p)), error = function(e) "not installed")
      sprintf("- %s (%s)", p, ver)
    }, character(1))
  } else "- (no library() calls found)"

  out <- c(
    "# Codebook & Reproducibility README",
    "",
    sprintf("Generated %s from `%s`", format(Sys.time(), "%Y-%m-%d %H:%M"), project_dir),
    sprintf("R version: %s", R.version.string),
    "",
    "## Packages used",
    "",
    pkg_lines,
    "",
    "## Scripts",
    "",
    if (length(scripts) > 0) {
      paste0("- `", sub(paste0("^", project_dir, "/?"), "", scripts, fixed = FALSE), "`")
    } else "- (none found)",
    "",
    "## Data files"
  )

  if (length(data_files) == 0) {
    out <- c(out, "", "No readable data files found (looked for .csv/.tsv/.txt/.rds read sites in scripts).", "")
  } else {
    for (f in data_files) {
      df <- read_data_file(f)
      rel <- sub(paste0("^", project_dir, "/?"), "", normalizePath(f, winslash = "/", mustWork = FALSE))
      if (is.null(df)) {
        out <- c(out, "", paste0("### ", rel), "", "Could not read as a data frame (unsupported format or malformed).", "")
      } else {
        out <- c(out, "", codebook_for_df(df, rel))
      }
    }
    if (dropped > 0) {
      out <- c(out, sprintf("(%d additional data files not documented; raise max_files.)", dropped), "")
    }
  }

  out <- c(out,
    "## Outputs produced by scripts",
    "",
    if (length(writes) > 0) paste0("- `", writes, "`") else "- (no write/save sites found)",
    ""
  )

  writeLines(out, output_path)
  message(sprintf("Codebook written: %s (%d packages, %d scripts, %d data files)",
                  output_path, length(pkgs), length(scripts), length(data_files)))
  invisible(output_path)
}
