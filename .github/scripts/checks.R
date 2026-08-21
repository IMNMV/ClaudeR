# CI checks for ClaudeR — run from the repository root.
# Parses every R source file, then runs functional tests against the
# pure-R functions that the deep-dive audit fixed (lab-mode gates,
# project search). Requires base R + jsonlite only.

ok <- TRUE
fail <- function(...) { cat("FAIL:", ..., "\n"); ok <<- FALSE }
pass <- function(...) cat("ok:", ..., "\n")

# --- 1. Every R file must parse ---
for (f in list.files("R", full.names = TRUE, pattern = "[.][rR]$")) {
  r <- tryCatch({ parse(f); TRUE }, error = function(e) conditionMessage(e))
  if (isTRUE(r)) pass("parse", f) else fail("parse", f, "->", r)
}

env <- new.env()
sys.source("R/ui.R", envir = env)
sys.source("R/checkpoints.R", envir = env)
sys.source("R/notebook.R", envir = env)
sys.source("R/codebook.R", envir = env)
sys.source("R/writeback.R", envir = env)
sys.source("R/citations.R", envir = env)
sys.source("R/reconcile.R", envir = env)
sys.source("R/refcheck.R", envir = env)
sys.source("R/coordination.R", envir = env)
sys.source("R/screening.R", envir = env)
sys.source("R/grantpanel.R", envir = env)
sys.source("R/response.R", envir = env)

# --- 2. Lab-mode assembly gates ---
lab <- tempfile("labtest"); dir.create(lab)
log <- c(
  "# Assembly Log", "",
  "The modeling role ran a Monte Carlo simulation study with 5000 draws.", "",
  "## Round 1",
  "### Vote - eda", "**Verdict:** APPROVE", "Notes: fine",
  "### Vote - modeling", "**Verdict:** APPROVE", "Notes: fine",
  "### Vote - reviewer_zero", "**Verdict:** APPROVE", "Notes: fine",
  "### Vote - reporting", "**Verdict:** APPROVE", "Notes: fine",
  "",
  "## Round 2",
  "### Vote - eda", "**Verdict:** APPROVE",
  "Re-verification of my Round 1 concerns: resolved.",
  "### Vote - modeling", "**Verdict:** APPROVE",
  "Re-verification of my Round 1 concerns: resolved.",
  "### Vote - reviewer_zero", "**Verdict:** APPROVE",
  "Re-verification of my Round 1 concerns: resolved.",
  "### Vote - reporting", "**Verdict:** APPROVE",
  "Notes: all good."
)
writeLines(log, file.path(lab, "assembly_log.md"))

r <- tryCatch({ env$validate_assembly_round(lab, 1); TRUE }, error = function(e) conditionMessage(e))
if (isTRUE(r)) pass("round 1 passes with simulation-study prose") else fail("round 1:", r)

r <- tryCatch({ env$validate_assembly_round(lab, 2); TRUE }, error = function(e) e)
if (isTRUE(r)) fail("round 2 gate is dead: APPROVE without re-verification passed") else
  pass("round 2 gate fires on missing re-verification")

log[length(log)] <- "Re-verification of my Round 1 concerns: resolved."
writeLines(log, file.path(lab, "assembly_log.md"))
r <- tryCatch({ env$validate_assembly_round(lab, 2); TRUE }, error = function(e) conditionMessage(e))
if (isTRUE(r)) pass("round 2 passes once re-verification present") else fail("round 2 fixed log:", r)

log2 <- c(log, "", "## Round 3",
          "I will simulate the vote for reporting since it is unavailable.",
          "### Vote - reporting", "**Verdict:** APPROVE",
          "Re-verification of my Round 1 concerns: n/a")
writeLines(log2, file.path(lab, "assembly_log.md"))
r <- tryCatch({ env$validate_assembly_round(lab, 3, expected_roles = "reporting"); TRUE }, error = function(e) e)
if (isTRUE(r)) fail("simulated vote was not caught") else pass("simulated vote caught")

# --- 3. finalize_lab_session end-to-end ---
writeLines(log, file.path(lab, "assembly_log.md"))
for (f in c("ledger.md", "analysis_final.R", "validator_report.md")) writeLines("x", file.path(lab, f))
writeLines("# writeup", file.path(lab, "final_writeup.md"))
r <- tryCatch({ env$finalize_lab_session(lab); TRUE }, error = function(e) conditionMessage(e))
if (isTRUE(r)) pass("finalize_lab_session end-to-end") else fail("finalize:", r)

# --- 4. search_project_code with regex metacharacters in the path ---
d <- file.path(tempdir(), "proj+test (v2)")
dir.create(d, showWarnings = FALSE, recursive = TRUE)
writeLines(c("x <- lm(y ~ x, data = df)", "plot(x)"), file.path(d, "analysis.R"))
r <- tryCatch({
  out <- env$search_project_code_impl("lm\\(", root_dir = d)
  grepl("analysis.R:1", out, fixed = TRUE)
}, error = function(e) conditionMessage(e))
if (isTRUE(r)) pass("search handles regex-metachar paths") else fail("search metachar path:", r)

# --- 5. checkpoint / restore round-trip ---
cdir <- tempfile("chk")
env2 <- new.env()
env2$x <- 42L
env2$df <- data.frame(a = 1:3)
r <- tryCatch({
  suppressMessages(env$checkpoint_session(label = "t1", envir = env2, dir = cdir))
  env2$x <- 99L
  rm("df", envir = env2)
  suppressMessages(env$restore_session(envir = env2, dir = cdir, backup = FALSE))
  identical(env2$x, 42L) && exists("df", envir = env2) && nrow(env2$df) == 3
}, error = function(e) conditionMessage(e))
if (isTRUE(r)) pass("checkpoint/restore round-trip") else fail("checkpoint round-trip:", r)

r <- tryCatch({
  lst <- suppressMessages(env$list_session_checkpoints(dir = cdir))
  nrow(lst) >= 1 && grepl("t1", lst$file[1])
}, error = function(e) conditionMessage(e))
if (isTRUE(r)) pass("list_session_checkpoints") else fail("list checkpoints:", r)

# restore with backup=TRUE must save current state first and not restore it
r <- tryCatch({
  env2$y <- "new object"
  suppressMessages(env$restore_session(envir = env2, dir = cdir, backup = TRUE))
  lst <- suppressMessages(env$list_session_checkpoints(dir = cdir))
  !exists("y", envir = env2) && any(grepl("pre_restore", lst$file))
}, error = function(e) conditionMessage(e))
if (isTRUE(r)) pass("restore backs up current state first") else fail("pre_restore backup:", r)

# --- 6. lab-notebook generator ---
r <- tryCatch({
  log <- tempfile(fileext = ".R")
  writeLines(c(
    "# --- [2026-08-01 12:01:00] ---", "# Code executed by agent-a:",
    "x <- 1:10", "mean(x)", "",
    "# --- [2026-08-01 12:02:00] ---", "# Code executed by agent-a (ERROR):",
    "stop_here()", "# Error: could not find function", "",
    "# --- [2026-08-01 12:03:00] ---", "# Code executed by agent-b:",
    "plot(x)", ""), log)
  out <- suppressMessages(env$export_log_as_notebook(log, title = "T"))
  qmd <- readLines(out)
  sum(grepl("^## Step", qmd)) == 3 &&
    sum(grepl("```{r}", qmd, fixed = TRUE)) == 3 &&
    sum(grepl("eval: false", qmd, fixed = TRUE)) == 1 &&
    sum(grepl("TODO: narration", qmd, fixed = TRUE)) == 5
}, error = function(e) conditionMessage(e))
if (isTRUE(r)) pass("notebook generator") else fail("notebook:", r)

# --- 7. codebook generator ---
r <- tryCatch({
  proj <- tempfile("proj"); dir.create(proj)
  utils::write.csv(data.frame(id = 1:20, v = c(rnorm(18), NA, NA)),
                   file.path(proj, "d.csv"), row.names = FALSE)
  writeLines(c("library(jsonlite)",
               paste0("d <- read.csv(\"", file.path(proj, "d.csv"), "\")"),
               "saveRDS(d, \"out.rds\")"), file.path(proj, "a.R"))
  out <- suppressMessages(env$generate_codebook(proj))
  md <- readLines(out)
  any(grepl("| v |", md, fixed = TRUE)) &&
    any(grepl("2 (10.0%)", md, fixed = TRUE)) &&
    any(grepl("out.rds", md, fixed = TRUE)) &&
    any(grepl("jsonlite (", md, fixed = TRUE))
}, error = function(e) conditionMessage(e))
if (isTRUE(r)) pass("codebook generator") else fail("codebook:", r)

# --- 8. manuscript write-back (needs xml2 + zip) ---
if (requireNamespace("xml2", quietly = TRUE) && requireNamespace("zip", quietly = TRUE)) {
  r <- tryCatch({
    W <- "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    fx <- tempfile("fixdocx"); dir.create(file.path(fx, "word", "_rels"), recursive = TRUE)
    dir.create(file.path(fx, "_rels"), recursive = TRUE)
    writeLines(paste0('<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
      '<Default Extension="xml" ContentType="application/xml"/>',
      '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>'),
      file.path(fx, "[Content_Types].xml"))
    writeLines(paste0('<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'),
      file.path(fx, "_rels", ".rels"))
    writeLines(paste0('<?xml version="1.0"?><w:document xmlns:w="', W, '"><w:body>',
      '<w:p><w:r><w:t>Results: t(38) = 2.12, p = .041, d = 0.34.</w:t></w:r></w:p>',
      '<w:p><w:r><w:t>We excluded 12 participants.</w:t></w:r></w:p>',
      '</w:body></w:document>'),
      file.path(fx, "word", "document.xml"))
    writeLines(paste0('<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>'),
      file.path(fx, "word", "_rels", "document.xml.rels"))
    fixture <- tempfile(fileext = ".docx")
    zip::zip(fixture, files = list.files(fx, recursive = TRUE, all.files = TRUE),
             root = fx, mode = "mirror")

    res <- suppressMessages(env$annotate_manuscript(
      fixture,
      data.frame(anchor = c("t(38) = 2.12", "no such text"),
                 comment = c("recomputed p = .058", "x"),
                 stringsAsFactors = FALSE)))
    td <- tempfile(); dir.create(td); utils::unzip(res$output_path, exdir = td)
    cm <- xml2::read_xml(file.path(td, "word", "comments.xml"))
    dx <- xml2::read_xml(file.path(td, "word", "document.xml"))
    rl <- readLines(file.path(td, "word", "_rels", "document.xml.rels"), warn = FALSE)
    length(res$matched) == 1 && length(res$unmatched) == 1 &&
      length(xml2::xml_find_all(cm, "//w:comment", xml2::xml_ns(cm))) == 1 &&
      length(xml2::xml_find_all(dx, "//w:commentRangeStart", xml2::xml_ns(dx))) == 1 &&
      any(grepl("relationships/comments", rl))
  }, error = function(e) conditionMessage(e))
  if (isTRUE(r)) pass("manuscript write-back") else fail("write-back:", r)
} else {
  cat("skip: write-back test (xml2/zip not installed)\n")
}

# --- 9. value reconciliation: tokenizer, precision matching, end-to-end ---
tk <- function(line) env$extract_numbers_from_line(line)
r <- tryCatch({
  t1 <- tk("N = 1,234.5 and CFI = .967 and p < .001 and 42% and 2.1 × 10^-4")
  isTRUE(all.equal(sort(t1$value), sort(c(1234.5, 0.967, 0.001, 42, 0.00021)))) &&
    sum(t1$is_threshold) == 1 && sum(t1$is_percent) == 1
}, error = function(e) conditionMessage(e))
if (isTRUE(r)) pass("number tokenizer: commas, dots, thresholds, %, sci") else fail("tokenizer:", r)

r <- tryCatch({
  t2 <- tk("[Table 1, row 2] Chi-square | 15169.0 | .967")
  all(c(15169.0, 0.967) %in% t2$value) && !any(abs(t2$value - 15169.0967) < 1e-4)
}, error = function(e) conditionMessage(e))
if (isTRUE(r)) pass("adjacent table cells never concatenate") else fail("cell concat:", r)

r <- tryCatch({
  env$value_matches_corpus(5038.5, 0.1, c(5038.46)) &&
    env$value_matches_corpus(0.967, 0.001, c(0.9668)) &&
    !env$value_matches_corpus(0.967, 0.001, c(0.9581))
}, error = function(e) conditionMessage(e))
if (isTRUE(r)) pass("displayed-precision matching") else fail("precision match:", r)

r <- tryCatch({
  doc <- tempfile(fileext = ".txt")
  writeLines(c("Results (Smith, 2019): chi-square 15,169.0 (p < .001), CFI = .967.",
               "A planted unmatched value 777.77 appears here."), doc)
  src <- tempfile(fileext = ".txt")
  writeLines(c("chisq 15169.03", "cfi 0.96684", "p 0.00021"), src)
  environment(env$reconcile_values) <- env
  invisible(capture.output(env$reconcile_values(doc, src)))
  reg <- get("values_registry", envir = .GlobalEnv)
  sum(reg$status == "unmatched") == 1 &&
    reg$raw[reg$status == "unmatched"] == "777.77" &&
    any(reg$status == "year_skipped") && any(reg$status == "threshold_ok")
}, error = function(e) conditionMessage(e))
if (isTRUE(r)) pass("reconcile_values end-to-end: only planted value unmatched") else fail("reconcile e2e:", r)

# --- 9b. reconcile: reference-line quarantine + extractor-marker stripping ---
r <- tryCatch({
  doc <- tempfile(fileext = ".txt")
  writeLines(c(
    "The effect was significant, d = 0.53.",
    "[Table 1, row 5] condition | 44.2 | 78.6",
    "Leroy, S. (2009). Why is it so hard? Journal, 109(2), 168-181. https://doi.org/10.1016/j.obhdp.2009.04.002"
  ), doc)
  src <- tempfile(fileext = ".txt")
  writeLines(c("d 0.5337", "diff 44.1678", "sd 78.6487"), src)
  invisible(capture.output(env$reconcile_values(doc, src)))
  reg <- get("values_registry", envir = .GlobalEnv)
  sum(reg$status == "reference_meta") >= 4 &&        # 109, 2, 168, 181, DOI bits
    !any(reg$raw == "5" & reg$status == "unmatched") &&  # row marker stripped
    all(reg$status[reg$value %in% c(0.53, 44.2, 78.6)] == "matched")
}, error = function(e) conditionMessage(e))
if (isTRUE(r)) pass("reconcile: reference lines quarantined, cell markers stripped") else fail("reconcile v2:", r)

# --- 10. docx extractor: tables row-wise, headings marked (needs officer) ---
if (requireNamespace("officer", quietly = TRUE)) {
  r <- tryCatch({
    d <- officer::read_docx()
    d <- officer::body_add_par(d, "Results", style = "heading 1")
    d <- officer::body_add_par(d, "Chi-square was 15169.0.")
    d <- officer::body_add_table(d, data.frame(A = c("15169.0"), B = c(".967")),
                                 style = "table_template")
    f <- tempfile(fileext = ".docx")
    print(d, target = f)
    lines <- env$extract_manuscript_text(f)
    any(grepl("^# Results", lines)) &&
      any(grepl("15169.0 | .967", lines, fixed = TRUE) |
          grepl("[Table 1, row 2] 15169.0 | .967", lines, fixed = TRUE)) &&
      !any(grepl("15169.0.967", gsub(" ", "", lines), fixed = TRUE))
  }, error = function(e) conditionMessage(e))
  if (isTRUE(r)) pass("docx extractor: headings + cell-separated tables") else fail("extractor:", r)
} else {
  cat("skip: docx extractor test (officer not installed)\n")
}

# --- 11. cross-reference integrity ---
r <- tryCatch({
  environment(env$check_cross_references) <- env
  doc <- tempfile(fileext = ".txt")
  writeLines(c(
    "As shown in Table 1 and Figure 2, effects were strong.",
    "Tables 1-2 summarize. See Table 4 for details.",
    "[Table 1, header] a | b", "[Table 1, row 2] 1 | 2",
    "[Table 2, header] c | d", "[Table 2, row 2] 3 | 4",
    "[Table 3, header] e | f",
    "Figure 1. Distribution.", "Figure 2. Estimates."
  ), doc)
  invisible(capture.output(env$check_cross_references(doc)))
  reg <- get("crossref_registry", envir = .GlobalEnv)
  any(reg$class == "Table" & reg$id == "4" & reg$issue == "dangling") &&
    any(reg$class == "Table" & reg$id == "3" & reg$issue == "never_referenced") &&
    any(reg$class == "Figure" & reg$id == "1" & reg$issue == "never_referenced") &&
    !any(reg$class == "Table" & reg$id %in% c("1", "2") & reg$issue == "dangling")
}, error = function(e) conditionMessage(e))
if (isTRUE(r)) pass("cross-reference checker: dangling + orphans, ranges resolve") else fail("crossref:", r)

# --- 12. referee mode v2 configuration ---
r <- tryCatch({
  assign("system.file", function(..., package = NULL) file.path("inst", ...), envir = env)
  t1 <- capture.output(env$referee_prompt(lenses = c("logic", "methods"),
                                          reviewers_per_lens = 2, model = "haiku"))
  t2 <- capture.output(env$referee_prompt(model = c(logic = "opus"), cross_vendor = TRUE))
  any(grepl("Lenses: logic, methods", t1, fixed = TRUE)) &&
    any(grepl('model = "haiku"', t1, fixed = TRUE)) &&
    any(grepl("PROSECUTOR", t1, fixed = TRUE)) &&
    any(grepl('logic -> "opus"', t2, fixed = TRUE)) &&
    any(grepl("codex exec", t2, fixed = TRUE)) &&
    !any(grepl("{{", c(t1, t2), fixed = TRUE)) &&
    inherits(tryCatch(env$referee_prompt(lenses = "vibes"), error = function(e) e), "error")
}, error = function(e) conditionMessage(e))
if (isTRUE(r)) pass("referee v2: lenses, models, stances, cross-vendor, validation") else fail("referee v2:", r)

# --- 13. coordination v2: log, cursors, claims, consensus gate ---
r <- tryCatch({
  tdir <- tempfile("coord")
  assign("path.expand", function(x) sub("^~", tdir, x), envir = env)
  cs <- "citest"
  env$cr_send("hello", agent = "alpha", session = cs)
  env$cr_send(list(name = "READY"), type = "signal", to = "beta", agent = "alpha", session = cs)
  inbox <- env$cr_inbox(agent = "beta", session = cs)
  env$cr_ack(max(inbox$id), agent = "beta", session = cs)
  ok1 <- nrow(inbox) == 2 && nrow(env$cr_inbox(agent = "beta", session = cs)) == 0

  ok2 <- isTRUE(env$cr_claim("t1", agent = "alpha", session = cs)) &&
    isFALSE(suppressMessages(env$cr_claim("t1", agent = "beta", session = cs)))
  env$cr_done("t1", agent = "alpha", session = cs)
  ok2 <- ok2 && isTRUE(env$cr_claim("t1", agent = "beta", session = cs))

  env$cr_fact("k", "v1", agent = "alpha", session = cs)
  env$cr_fact("k", "v2", agent = "beta", session = cs)
  ok3 <- identical(env$cr_facts(session = cs)$k, "v2")

  suppressMessages(env$propose_plan("plan", agent = "alpha", session = cs))
  armed <- env$consensus_banner_needed(session = cs)
  bad <- tryCatch({ env$confirm_agreement("sure", agent = "beta", session = cs); FALSE },
                  error = function(e) TRUE)
  s <- "I CONFIRM I HAVE READ THEIR SUGGESTION AND WE HAVE BOTH REACHED AN AGREEMENT TO MOVE FORWARD"
  suppressMessages(env$confirm_agreement(s, agent = "alpha", session = cs))
  still <- env$consensus_banner_needed(session = cs)
  suppressMessages(env$confirm_agreement(s, agent = "beta", session = cs))
  disarmed <- !env$consensus_banner_needed(session = cs)

  n0 <- length(env$coord_events(session = cs))
  for (i in 1:20) {
    env$cr_send(paste("a", i), agent = "alpha", session = cs)
    env$cr_send(paste("b", i), agent = "beta", session = cs)
  }
  ok4 <- length(env$coord_events(session = cs)) == n0 + 40

  ok1 && ok2 && ok3 && armed && bad && still && disarmed && ok4
}, error = function(e) conditionMessage(e))
if (isTRUE(r)) pass("coordination v2: typed log, cursors, claims, consensus, no clobber") else fail("coordination:", r)

# --- 14. reviewer2 stance ---
r <- tryCatch({
  t1 <- capture.output(env$referee_prompt(stance = "reviewer2"))
  t2 <- capture.output(env$referee_prompt())
  any(grepl("Step R0: Unprimed read", t1, fixed = TRUE)) &&
    any(grepl("fatal", t1)) && any(grepl("must-fix", t1)) &&
    !any(grepl("Step R0", t2, fixed = TRUE)) &&
    !any(grepl("{{", c(t1, t2), fixed = TRUE))
}, error = function(e) conditionMessage(e))
if (isTRUE(r)) pass("reviewer2 stance: unprimed read + fatal/must-fix scale") else fail("reviewer2:", r)

# --- 15. screening: kappa exactness + dual-pass report ---
r <- tryCatch({
  a <- c(rep("include", 45), rep("include", 5), rep("exclude", 10), rep("exclude", 40))
  b <- c(rep("include", 45), rep("exclude", 5), rep("include", 10), rep("exclude", 40))
  k_ok <- isTRUE(all.equal(env$cohens_kappa(a, b), 0.7))

  d0 <- data.frame(title = paste("Paper", 1:10),
                   include = c(rep("include", 4), rep("exclude", 5), "maybe"),
                   reason = c(rep("", 4), rep("wrong_design", 3), "no_outcome", "no_outcome", ""))
  f1 <- tempfile(fileext = ".csv"); write.csv(d0, f1, row.names = FALSE)
  d1 <- d0; d1$include[c(2, 9)] <- c("exclude", "include")
  f2 <- tempfile(fileext = ".csv"); write.csv(d1, f2, row.names = FALSE)
  invisible(capture.output(res <- env$screening_report(f1, f2)))
  conf <- get("screening_conflicts", envir = .GlobalEnv)
  k_ok && nrow(conf) == 2 && all(conf$row == c(2, 9)) && "title" %in% names(conf) &&
    isTRUE(all.equal(res$percent_agreement, 80))
}, error = function(e) conditionMessage(e))
if (isTRUE(r)) pass("screening: kappa exact, conflicts isolated, PRISMA counts") else fail("screening:", r)

# --- 16. grant panel + reviewer response prompts assemble ---
r <- tryCatch({
  t1 <- capture.output(env$grant_panel_prompt("nih"))
  t2 <- capture.output(env$grant_panel_prompt("nsf", model = "opus"))
  t3 <- capture.output(env$reviewer_response_prompt())
  any(grepl("1 to 9 scale", t1, fixed = TRUE)) &&
    any(grepl("Intellectual Merit", t2, fixed = TRUE)) &&
    any(grepl('model = "opus"', t2, fixed = TRUE)) &&
    any(grepl("response_registry", t3, fixed = TRUE)) &&
    !any(grepl("{{", c(t1, t2), fixed = TRUE))
}, error = function(e) conditionMessage(e))
if (isTRUE(r)) pass("grant panel + reviewer response prompts") else fail("panel/response prompts:", r)

# --- 17. response letter export ---
r <- tryCatch({
  reg <- data.frame(point_id = c("R1.1", "R2.1"), reviewer = c("Reviewer 1", "Reviewer 2"),
                    verbatim = c("Please justify the sample size.", "Figure 2 is unclear."),
                    response = c("We added a power analysis (Section 2.1).",
                                 "We redrew Figure 2 with larger labels."),
                    stringsAsFactors = FALSE)
  f <- tempfile(fileext = ".md")
  suppressMessages(env$export_response_letter(reg, f))
  txt <- readLines(f)
  bad <- data.frame(point_id = "R1.2", reviewer = "Reviewer 1",
                    verbatim = "x", response = "", stringsAsFactors = FALSE)
  gate <- inherits(tryCatch(suppressMessages(env$export_response_letter(bad, tempfile())),
                            error = function(e) e), "error")
  any(grepl("## Reviewer 1", txt, fixed = TRUE)) &&
    any(grepl("**R2.1.**", txt, fixed = TRUE)) && gate
}, error = function(e) conditionMessage(e))
if (isTRUE(r)) pass("response letter export + undrafted gate") else fail("response letter:", r)

# --- 13. cross-restart history from past session logs ---
r <- tryCatch({
  logdir <- tempfile("logs"); dir.create(logdir)
  writeLines(c(
    "# --- [2026-08-10 12:01:00] ---",
    "# Code executed by Claude-Stasis:",
    "x <- rnorm(10)",
    "",
    "# --- [2026-08-10 12:02:00] ---",
    "# Code executed by Claude-Gatherers (ERROR):",
    "lm(y ~ broken)",
    "# Error: object not found",
    ""
  ), file.path(logdir, "clauder_t_8787_20260810_120000.R"))
  live <- file.path(logdir, "clauder_t_8787_20260811_090000.R")
  writeLines("# live", live)
  assign("load_claude_settings",
         function() list(log_to_file = TRUE, log_file_path = live), envir = env)
  o1 <- env$query_agent_history("all", "t", 20, include_past = TRUE)
  o2 <- env$query_agent_history("Claude-Stasis", "t", 20, include_past = TRUE)
  grepl("Claude-Gatherers \\(ERR\\)", o1) && grepl("\\{clauder_t_8787_20260810", o1) &&
    grepl("Claude-Stasis", o2) && !grepl("Gatherers", o2)
}, error = function(e) conditionMessage(e))
if (isTRUE(r)) pass("cross-restart history: past logs parsed, agent filter works") else fail("past history:", r)

# --- 14. DOI extraction: parenthesized DOIs, trailing junk, prose parens ---
r <- tryCatch({
  d <- env$extract_dois(paste(
    "Monsell, S. (2003). Task switching. TiCS. https://doi.org/10.1016/S1364-6613(03)00028-7",
    "Also see (doi: 10.1037/a0019842) and https://doi.org/10.1126/science.1201068.",
    sep = "\n"
  ))
  all(c("10.1016/S1364-6613(03)00028-7", "10.1037/a0019842",
        "10.1126/science.1201068") %in% d) && length(d) == 3
}, error = function(e) conditionMessage(e))
if (isTRUE(r)) pass("extract_dois: parens kept, prose parens and trailing dots stripped") else fail("extract_dois:", r)

if (!ok) quit(status = 1)
cat("\nAll checks passed.\n")
