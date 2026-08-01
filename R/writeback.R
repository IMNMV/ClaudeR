# --- Manuscript Write-back ---
# Injects native Word comments into a .docx at the paragraphs containing
# flagged text, so a Reviewer Zero audit lands as reviewable annotations the
# author can accept/dismiss in Word, not just a report table. Pure OOXML
# surgery via xml2 + zip (both Suggests); the original file is never touched.

#' Annotate a .docx manuscript with Word comments
#'
#' For each row of `annotations`, finds the first paragraph whose text
#' contains `anchor` and attaches a native Word comment spanning that
#' paragraph. Writes to a new file; the original is never modified.
#'
#' @param docx_path Path to the manuscript (.docx).
#' @param annotations A data.frame with columns `anchor` (verbatim substring
#'   to locate; whitespace is normalized for matching) and `comment` (the
#'   comment text to attach).
#' @param author Comment author shown in Word. Default "Reviewer Zero".
#' @param output_path Output .docx path. Default: input path with an
#'   `_annotated.docx` suffix. Must differ from the input.
#' @return Invisibly, a list with `output_path`, `matched`, and `unmatched`
#'   (anchors that were not found).
#' @export
annotate_manuscript <- function(docx_path, annotations,
                                author = "Reviewer Zero",
                                output_path = NULL) {
  for (pkg in c("xml2", "zip")) {
    if (!requireNamespace(pkg, quietly = TRUE)) {
      stop(sprintf("The '%s' package is required. Install with install.packages('%s')", pkg, pkg),
           call. = FALSE)
    }
  }
  docx_path <- path.expand(docx_path)
  if (!file.exists(docx_path)) stop("File not found: ", docx_path, call. = FALSE)
  if (!is.data.frame(annotations) ||
      !all(c("anchor", "comment") %in% names(annotations)) ||
      nrow(annotations) == 0) {
    stop("`annotations` must be a data.frame with columns 'anchor' and 'comment' and at least one row.",
         call. = FALSE)
  }
  if (is.null(output_path)) {
    output_path <- sub("\\.docx$", "_annotated.docx", docx_path, ignore.case = TRUE)
    if (output_path == docx_path) output_path <- paste0(docx_path, "_annotated.docx")
  }
  output_path <- path.expand(output_path)
  if (normalizePath(output_path, mustWork = FALSE) ==
      normalizePath(docx_path, mustWork = FALSE)) {
    stop("output_path must differ from docx_path; the original is never overwritten.",
         call. = FALSE)
  }

  td <- tempfile("docx_annot_")
  dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)
  utils::unzip(docx_path, exdir = td)

  doc_file <- file.path(td, "word", "document.xml")
  if (!file.exists(doc_file)) stop("Not a valid .docx (word/document.xml missing).", call. = FALSE)
  doc <- xml2::read_xml(doc_file)
  ns <- xml2::xml_ns(doc)

  squish <- function(x) trimws(gsub("\\s+", " ", x))

  paras <- xml2::xml_find_all(doc, "//w:p", ns)
  para_text <- vapply(paras, function(p) {
    squish(paste(xml2::xml_text(xml2::xml_find_all(p, ".//w:t", ns)), collapse = ""))
  }, character(1))

  # comments.xml: extend if present, create otherwise
  comments_file <- file.path(td, "word", "comments.xml")
  had_comments <- file.exists(comments_file)
  comments <- if (had_comments) {
    xml2::read_xml(comments_file)
  } else {
    xml2::read_xml(paste0(
      '<w:comments xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"/>'
    ))
  }
  existing_ids <- xml2::xml_attr(
    xml2::xml_find_all(comments, "//w:comment", xml2::xml_ns(comments)), "id")
  next_id <- if (length(existing_ids) > 0) {
    max(suppressWarnings(as.integer(existing_ids)), na.rm = TRUE) + 1L
  } else 0L

  initials <- toupper(paste(substr(strsplit(author, "\\s+")[[1]], 1, 1), collapse = ""))
  if (!nzchar(initials)) initials <- "RZ"
  stamp <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

  matched <- character(0)
  unmatched <- character(0)

  for (i in seq_len(nrow(annotations))) {
    anchor <- squish(as.character(annotations$anchor[i]))
    ctext <- as.character(annotations$comment[i])
    if (!nzchar(anchor)) { unmatched <- c(unmatched, anchor); next }

    hit <- which(vapply(para_text, function(t) grepl(anchor, t, fixed = TRUE), logical(1)))
    if (length(hit) == 0) { unmatched <- c(unmatched, anchor); next }
    p <- paras[[hit[1]]]
    cid <- as.character(next_id)
    next_id <- next_id + 1L

    # Range start goes after pPr (paragraph properties must stay first)
    ppr <- xml2::xml_find_first(p, "./w:pPr", ns)
    if (!inherits(ppr, "xml_missing")) {
      xml2::xml_add_sibling(ppr, "w:commentRangeStart", "w:id" = cid,
                            .where = "after")
    } else {
      xml2::xml_add_child(p, "w:commentRangeStart", "w:id" = cid, .where = 0)
    }
    xml2::xml_add_child(p, "w:commentRangeEnd", "w:id" = cid)
    ref_run <- xml2::xml_add_child(p, "w:r")
    xml2::xml_add_child(ref_run, "w:commentReference", "w:id" = cid)

    # The comment body
    cm <- xml2::xml_add_child(comments, "w:comment",
                              "w:id" = cid, "w:author" = author,
                              "w:date" = stamp, "w:initials" = initials)
    cp <- xml2::xml_add_child(cm, "w:p")
    cr <- xml2::xml_add_child(cp, "w:r")
    ct <- xml2::xml_add_child(cr, "w:t", ctext)
    xml2::xml_set_attr(ct, "xml:space", "preserve")

    matched <- c(matched, anchor)
  }

  if (length(matched) == 0) {
    stop("No anchors matched any paragraph. Check that anchors are verbatim substrings of the manuscript text.",
         call. = FALSE)
  }

  xml2::write_xml(doc, doc_file)
  xml2::write_xml(comments, comments_file)

  # Register the comments part (content type + relationship). Checked
  # unconditionally and idempotently: some templates ship a comments.xml
  # without wiring it up, and Word only renders comments it can reach
  # through the relationship.
  ct_file <- file.path(td, "[Content_Types].xml")
  ct <- xml2::read_xml(ct_file)
  ct_ns <- xml2::xml_ns(ct)
  has_ct <- length(xml2::xml_find_all(
    ct, "//d1:Override[@PartName='/word/comments.xml']", ct_ns)) > 0
  if (!has_ct) {
    xml2::xml_add_child(ct, "Override",
      PartName = "/word/comments.xml",
      ContentType = "application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml")
    xml2::write_xml(ct, ct_file)
  }

  rels_file <- file.path(td, "word", "_rels", "document.xml.rels")
  rels <- xml2::read_xml(rels_file)
  rels_ns <- xml2::xml_ns(rels)
  rel_nodes <- xml2::xml_find_all(rels, "//d1:Relationship", rels_ns)
  has_rel <- any(grepl("/comments$", xml2::xml_attr(rel_nodes, "Type")))
  if (!has_rel) {
    rid_nums <- suppressWarnings(as.integer(sub("^rId", "", xml2::xml_attr(rel_nodes, "Id"))))
    new_rid <- paste0("rId", max(c(rid_nums, 0L), na.rm = TRUE) + 1L)
    xml2::xml_add_child(rels, "Relationship",
      Id = new_rid,
      Type = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments",
      Target = "comments.xml")
    xml2::write_xml(rels, rels_file)
  }

  # Rezip. mode = "mirror" preserves paths relative to root ("cherry-pick"
  # would flatten everything to the archive root and corrupt the docx).
  if (file.exists(output_path)) file.remove(output_path)
  zip::zip(zipfile = output_path,
           files = list.files(td, recursive = TRUE, all.files = TRUE),
           root = td, mode = "mirror")

  message(sprintf("Annotated manuscript written: %s (%d comments placed, %d anchors unmatched)",
                  output_path, length(matched), length(unmatched)))
  invisible(list(output_path = output_path, matched = matched,
                 unmatched = unmatched))
}
