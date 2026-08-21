# --- Citation tools ---
# Network helpers behind the search_citations / get_bibtex MCP tools and the
# retraction / arXiv / no-DOI extensions to verify_references. All requests
# are bounded by options(timeout = 10) at the call site and wrapped in
# tryCatch so one dead API never kills a whole report.

# Query OpenAlex for works matching a free-text query. Returns a formatted
# candidate list the agent can pick a citation from (instead of hallucinating
# one). OpenAlex needs no API key and tolerates polite anonymous use.
search_citations_impl <- function(query, max_results = 5L) {
  if (!nzchar(trimws(query))) return("Error: empty query.")
  old <- options(timeout = 10)
  on.exit(options(old), add = TRUE)

  url <- paste0(
    "https://api.openalex.org/works?search=",
    utils::URLencode(query, reserved = TRUE),
    "&per-page=", as.integer(max_results),
    "&select=title,authorships,publication_year,primary_location,doi,cited_by_count,type"
  )
  res <- tryCatch(jsonlite::fromJSON(url, simplifyVector = FALSE),
                  error = function(e) NULL)
  if (is.null(res) || length(res$results) == 0) {
    return(paste0("No OpenAlex results for: ", query))
  }

  entries <- vapply(res$results, function(w) {
    authors <- vapply(w$authorships, function(a) {
      an <- a$author$display_name
      if (is.null(an)) "?" else an
    }, character(1))
    if (length(authors) > 4) authors <- c(authors[1:3], "et al.")
    venue <- tryCatch(w$primary_location$source$display_name,
                      error = function(e) NULL)
    doi <- if (!is.null(w$doi)) sub("^https://doi.org/", "", w$doi) else "no DOI"
    paste0(
      "- ", if (!is.null(w$title)) w$title else "(untitled)", "\n",
      "  ", paste(authors, collapse = ", "),
      " (", if (!is.null(w$publication_year)) w$publication_year else "?", "). ",
      if (!is.null(venue)) venue else "unknown venue", ".\n",
      "  DOI: ", doi,
      " | type: ", if (!is.null(w$type)) w$type else "?",
      " | cited by: ", if (!is.null(w$cited_by_count)) w$cited_by_count else "?"
    )
  }, character(1))

  paste0(
    "OpenAlex results for '", query, "' (", length(entries), "):\n\n",
    paste(entries, collapse = "\n\n"),
    "\n\nUse get_bibtex with a DOI to fetch a citation entry."
  )
}

# Fetch a BibTeX entry for a DOI via doi.org content negotiation. This is the
# canonical registered metadata, not a reconstruction.
get_bibtex_impl <- function(doi) {
  doi <- sub("^https?://doi.org/", "", trimws(doi))
  if (!grepl("^10\\.\\d{4,9}/", doi)) {
    return(paste0("Error: '", doi, "' does not look like a DOI (expected 10.XXXX/...)."))
  }
  old <- options(timeout = 10)
  on.exit(options(old), add = TRUE)

  bib <- tryCatch({
    con <- url(paste0("https://doi.org/", doi),
               headers = c(Accept = "application/x-bibtex"))
    on.exit(try(close(con), silent = TRUE), add = TRUE)
    paste(readLines(con, warn = FALSE), collapse = "\n")
  }, error = function(e) NULL)

  if (is.null(bib) || !nzchar(bib)) {
    return(paste0("Could not resolve BibTeX for DOI ", doi,
                  ". The DOI may be invalid or the resolver unreachable."))
  }
  bib
}

# Extract DOIs from text using the Crossref-recommended character class,
# which allows parentheses: legacy Elsevier DOIs like
# 10.1016/S1364-6613(03)00028-7 are common in psychology bibliographies and
# were truncated at the paren by the old pattern, producing false 404s.
# Trailing punctuation and unbalanced closing brackets (from prose like
# "(doi: 10.1037/a0019842)") are stripped after matching.
extract_dois <- function(text) {
  pattern <- "10\\.\\d{4,9}/[-._;()/:a-zA-Z0-9]+"
  dois <- regmatches(text, gregexpr(pattern, text, perl = TRUE))[[1]]
  dois <- unique(trimws(dois))
  dois <- sub("[.,;:]+$", "", dois)
  strip_unbalanced <- function(d) {
    repeat {
      last <- substr(d, nchar(d), nchar(d))
      if (!last %in% c(")", "]")) break
      opener <- if (last == ")") "(" else "["
      n_open <- lengths(regmatches(d, gregexpr(opener, d, fixed = TRUE)))
      n_close <- lengths(regmatches(d, gregexpr(last, d, fixed = TRUE)))
      if (n_close > n_open) {
        d <- sub("[.,;:]+$", "", substr(d, 1, nchar(d) - 1))
      } else break
    }
    d
  }
  unique(vapply(dois, strip_unbalanced, character(1), USE.NAMES = FALSE))
}

# GET a Crossref API URL with retry/backoff. Crossref rate-limits bursts
# (HTTP 429); a failed lookup mid-audit silently truncates the reference
# check, so wait and retry before giving up.
crossref_get <- function(url, simplify = FALSE) {
  waits <- c(0, 1.5, 5)
  for (k in seq_along(waits)) {
    if (waits[k] > 0) Sys.sleep(waits[k])
    # base R surfaces the HTTP status in a *warning* ("HTTP status was '404
    # Not Found'") while the error message only says "cannot open URL", so
    # both conditions must be sniffed to tell a real 404 from rate limiting.
    saw_404 <- FALSE
    res <- withCallingHandlers(
      tryCatch(jsonlite::fromJSON(url, simplifyVector = simplify),
               error = function(e) e),
      warning = function(w) {
        if (grepl("404", conditionMessage(w))) saw_404 <<- TRUE
        invokeRestart("muffleWarning")
      }
    )
    if (!inherits(res, "error")) return(res)
    if (saw_404 || grepl("404", conditionMessage(res))) return(NULL)
  }
  NULL
}

# Check whether anything in Crossref updates this DOI (retractions,
# expressions of concern, major corrections). Returns NULL when clean,
# otherwise a short human-readable flag string.
check_retraction_impl <- function(doi) {
  res <- crossref_get(
    paste0("https://api.crossref.org/works?filter=updates:",
           utils::URLencode(doi, reserved = TRUE), "&rows=5")
  )
  if (is.null(res)) return(NULL)
  items <- res$message$items
  if (length(items) == 0) return(NULL)

  flags <- character(0)
  for (it in items) {
    for (upd in it$`update-to`) {
      type <- tolower(if (!is.null(upd$type)) upd$type else "")
      lab <- if (!is.null(upd$label)) upd$label else upd$type
      if (identical(upd$DOI, doi) || grepl("retract|concern|correct", type)) {
        notice_doi <- if (!is.null(it$DOI)) it$DOI else "?"
        flags <- c(flags, sprintf("%s (notice DOI: %s)", lab, notice_doi))
      }
    }
  }
  if (length(flags) == 0) return(NULL)
  paste0("!!! UPDATE NOTICE: ", paste(unique(flags), collapse = "; "),
         " -- verify before citing (possible retraction/correction/concern)")
}

# Best-effort bibliographic match for a reference string with no DOI.
# Returns a short candidate line, or NULL if nothing plausible came back.
match_reference_impl <- function(ref_text) {
  ref_text <- trimws(gsub("\\s+", " ", ref_text))
  if (nchar(ref_text) < 40) return(NULL)
  res <- crossref_get(
    paste0("https://api.crossref.org/works?rows=1&query.bibliographic=",
           utils::URLencode(substr(ref_text, 1, 300), reserved = TRUE))
  )
  items <- tryCatch(res$message$items, error = function(e) NULL)
  if (is.null(items) || length(items) == 0) return(NULL)
  it <- items[[1]]
  title <- tryCatch(paste(unlist(it$title), collapse = " "), error = function(e) "?")
  year <- tryCatch(it$issued$`date-parts`[[1]][[1]], error = function(e) "?")
  score <- if (!is.null(it$score)) round(as.numeric(it$score), 1) else NA
  sprintf("Best Crossref match: \"%s\" (%s), DOI: %s [score %s -- verify title/authors match before accepting]",
          title, year, if (!is.null(it$DOI)) it$DOI else "?", score)
}

# Look up an arXiv ID via the arXiv Atom API, and check Crossref for a
# published (journal/proceedings) version so preprint citations of published
# work get flagged. Atom parsed with regex to avoid an xml2 hard dependency.
check_arxiv_impl <- function(arxiv_id) {
  # export.arxiv.org is slow enough to trip a 10s timeout on cold requests;
  # retry with a longer allowance before giving up.
  res <- NULL
  for (k in 1:3) {
    if (k > 1) Sys.sleep(2)
    old_t <- options(timeout = if (k == 1) 10 else 25)
    res <- tryCatch({
      con <- url(paste0("https://export.arxiv.org/api/query?id_list=", arxiv_id))
      txt <- suppressWarnings(paste(readLines(con, warn = FALSE), collapse = "\n"))
      try(close(con), silent = TRUE)
      txt
    }, error = function(e) NULL)
    options(old_t)
    if (!is.null(res) && nzchar(res)) break
  }
  if (is.null(res) || !nzchar(res)) {
    return(sprintf("arXiv:%s -- lookup failed (arXiv API unreachable); verify manually.", arxiv_id))
  }

  title <- regmatches(res, regexpr("<title>[^<]+</title>", res))
  # First <title> is the feed's own; the entry title is the second match
  titles <- regmatches(res, gregexpr("<title>[^<]+</title>", res))[[1]]
  entry_title <- if (length(titles) >= 2) {
    trimws(gsub("</?title>|\\s+", " ", titles[2]))
  } else NULL
  if (is.null(entry_title) || !nzchar(entry_title)) {
    return(sprintf("arXiv:%s -- not found on arXiv.", arxiv_id))
  }

  out <- sprintf("arXiv:%s resolves to: \"%s\"", arxiv_id, entry_title)
  published <- match_reference_impl(entry_title)
  if (!is.null(published)) {
    out <- paste0(out, "\n  Possible published version -- ", published,
                  "\n  If this matches, cite the published version rather than the preprint.")
  }
  out
}
