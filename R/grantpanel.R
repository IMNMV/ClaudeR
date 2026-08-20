# --- Grant Panel Mode ---
# A mock study section: one reviewer subagent per rubric criterion, chair
# synthesis, anchored weaknesses, and a what-would-move-the-score list.

#' Print the Grant Panel prompt
#'
#' Convenes a mock funding panel over a grant proposal. One reviewer per
#' rubric criterion (parallel subagents where the host CLI supports them),
#' anchored and verified weaknesses, an honest score, and a ranked list of
#' concrete revisions that would move the score. Findings can be written
#' into a .docx copy as Word comments.
#'
#' @param rubric `"nih"` (Significance, Investigators, Innovation, Approach,
#'   Environment, scored 1 to 9 where 1 is best, plus an Overall Impact
#'   score) or `"nsf"` (Intellectual Merit and Broader Impacts, rated
#'   Excellent to Poor).
#' @param model Optional model directive for reviewer subagents, as in
#'   [referee_prompt()]: one tier for all reviewers or a named vector by
#'   criterion.
#' @return The prompt text (invisibly), printed to the console.
#' @export
grant_panel_prompt <- function(rubric = c("nih", "nsf"), model = NULL) {
  rubric <- match.arg(rubric)

  rubric_block <- if (identical(rubric, "nih")) {
    paste0(
      "NIH study section. Criteria, one reviewer each:\n",
      "1. Significance: does the project address an important problem, and\n",
      "   will the field improve if the aims are achieved?\n",
      "2. Investigator(s): are the researchers well suited to the project?\n",
      "3. Innovation: does the application challenge current paradigms or\n",
      "   use novel concepts, approaches, or methods?\n",
      "4. Approach: are the strategy, methodology, and analyses\n",
      "   well-reasoned, rigorous, and feasible? Are pitfalls and\n",
      "   alternatives addressed? This criterion drives most scores.\n",
      "5. Environment: does the institutional environment support success?\n",
      "Scores use the NIH 1 to 9 scale where 1 is exceptional and 9 is\n",
      "poor. The chair also assigns an Overall Impact score on the same\n",
      "scale, which is not an average: it weighs the criteria as a real\n",
      "panel would, with Approach and Significance dominating."
    )
  } else {
    paste0(
      "NSF panel. Criteria, one reviewer each:\n",
      "1. Intellectual Merit: the potential to advance knowledge, the\n",
      "   soundness of the plan, the qualifications of the team, and access\n",
      "   to needed resources.\n",
      "2. Broader Impacts: the potential to benefit society, including\n",
      "   education, broadening participation, and dissemination.\n",
      "Each criterion is rated Excellent, Very Good, Good, Fair, or Poor,\n",
      "with a written rationale. The chair gives an overall funding\n",
      "recommendation: Highly Competitive, Competitive, or Not Competitive."
    )
  }

  model_directive <- if (is.null(model)) {
    paste0("inherit the session's model for every reviewer. Prefer the ",
           "strongest available tier: score-driving judgments deserve it.")
  } else if (is.null(names(model)) && length(model) == 1) {
    sprintf("pass model = \"%s\" when dispatching every reviewer subagent.", model)
  } else {
    paste0("per-criterion models: ",
           paste(sprintf("%s -> \"%s\"", names(model), model), collapse = ", "),
           ". Criteria not listed inherit the session's model.")
  }

  prompt_path <- system.file("prompts", "grant_panel.md", package = "ClaudeR")
  if (!nzchar(prompt_path) || !file.exists(prompt_path)) {
    stop("Grant panel prompt template not found. Is ClaudeR installed correctly?")
  }
  txt <- paste(readLines(prompt_path, warn = FALSE), collapse = "\n")
  txt <- gsub("{{RUBRIC_BLOCK}}", rubric_block, txt, fixed = TRUE)
  txt <- gsub("{{MODEL_DIRECTIVE}}", model_directive, txt, fixed = TRUE)
  cat(txt, "\n")
  invisible(txt)
}
