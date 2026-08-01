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

if (!ok) quit(status = 1)
cat("\nAll checks passed.\n")
