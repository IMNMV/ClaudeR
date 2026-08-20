# Response to Reviewers Protocol

You are helping the author answer a revise-and-resubmit decision. The
deliverables are a point-by-point response letter and an annotated
manuscript. Every reviewer point gets a response. Every factual answer is
grounded in analyses actually run in this session, never in numbers from
memory.

Setup, before anything else:

```r
options(pillar.sigfig = 7, tibble.print_max = Inf, tibble.width = Inf,
        width = 200, digits = 7)
letter_lines <- ClaudeR::extract_manuscript_text("path_to_decision_letter")
doc_lines <- ClaudeR::extract_manuscript_text("path_to_manuscript")
```

## Step P1: Parse the decision letter into points

Read the letter fully with paginated `read_file`. Split it into individual
reviewer points. A point is one distinct request or criticism, even when a
reviewer packs three into one paragraph. Build the registry:

```r
response_registry <- data.frame(
  point_id   = character(),  # "R1.1", "R1.2", "R2.1", "E.1" for editor
  reviewer   = character(),
  verbatim   = character(),  # exact quote from the letter
  type       = character(),  # clarification, new_analysis, rewrite,
                             # citation, disagreement, praise
  ms_anchor  = character(),  # verbatim quote locating the relevant
                             # manuscript passage, or "" if paper-wide
  status     = character(),  # "open", "drafted", "resolved"
  response   = character(),
  stringsAsFactors = FALSE
)
```

Prove every verbatim quote exists:
`stopifnot(any(grepl(substring, letter_lines, fixed = TRUE)))`. Points of
type praise still get a row and a one-line thank-you, so the letter is
complete.

## Step P2: Locate each point in the manuscript

For each point with a manuscript target, find the passage it concerns and
record a verbatim `ms_anchor` from `doc_lines`. Use `search_project_code`
for points about the analysis code.

## Step P3: Answer data questions with real computation

For every point of type new_analysis or any point whose answer contains a
number:

1. Run the analysis in this session with `execute_r`, or in a clean room
   with `probe_scripts(capture_output = TRUE)` when it must be free of the
   live environment.
2. Put the computed numbers in the response draft directly from the
   objects. Never type a statistic from memory.
3. If the new analysis changes a manuscript value, flag it: the manuscript
   edit and the response must both happen, and reconcile_values can verify
   the revised manuscript afterward.

## Step P4: Draft the responses

For each point, write the response in the registry using the standard
form: thank or acknowledge briefly, answer directly, state what changed in
the manuscript and where, or state respectfully why nothing changed. Rules
of tone: professional, specific, and never defensive. Where you disagree
with a reviewer, disagree with evidence: a computed result, a citation
found with `search_citations` and fetched with `get_bibtex`, or a design
fact.

## Step P5: Gate, letter, and write-back

Nothing ships while any point is open:

```r
stopifnot(all(response_registry$status %in% c("drafted", "resolved")))
```

Then:

1. `ClaudeR::export_response_letter(response_registry, "response_letter.md")`
   writes the point-by-point letter (and a .docx when pandoc is available).
2. Write the revision plan into the manuscript copy as Word comments via
   `ClaudeR::annotate_manuscript()`, one comment per point that requires
   an edit, anchored at `ms_anchor` and prefixed with the point id, for
   example `[R1.3] Add the sensitivity analysis here (see response letter)`.
3. Report: counts by type and reviewer, the points that require manuscript
   edits, any new analyses run with their results, and both file paths.

## Rules

1. Every point in the letter appears in the registry. The gate proves it.
2. Numbers in responses come from computation in this session. No
   exceptions.
3. The author approves the letter. Present drafts as drafts.
4. Disagreement is allowed and sometimes right, but it must carry
   evidence.
5. If a reviewer is factually wrong, say so with the computation that
   shows it, and stay polite.
