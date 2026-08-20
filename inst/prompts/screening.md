# Systematic Review Screening Protocol

You are running title and abstract screening for a systematic review. The
goal is PRISMA-conformant screening with two independent AI screeners from
different model families, so the human only reads the records the screeners
disagree on.

## Step 1: Prepare the records file

Start from the deduplicated database export as a CSV. Each row is one
record. Keep at least a title column and an abstract column. Add a
`_schema` column whose first row defines the screening fields. Build the
reason list from the review's prespecified exclusion criteria:

```
include:choice[include,exclude,maybe];reason:choice[wrong_population,wrong_design,no_outcome,not_empirical,duplicate,other];notes:text
```

Rules for the schema:
- The decision field must be named `include` with exactly the values
  include, exclude, maybe.
- Every exclusion criterion from the protocol becomes one reason value.
- `maybe` is for records the criteria cannot settle from the abstract.
  These go to full-text screening.

## Step 2: Run the first screening pass

Use the `run_annotation_job` tool on the CSV. The job prompt comes from the
schema, so state the inclusion and exclusion criteria clearly in the notes
you give the tool. Each record is judged by a fresh subprocess with no
memory of other records. The judgment cannot drift over the run the way a
tired human screener drifts.

Pick the backend by budget. A local ollama model costs nothing and can
screen thousands of records overnight. A hosted model (claude, codex,
gemini) costs subscription usage and screens with higher quality.

## Step 3: Run the second pass with a DIFFERENT model family

Copy the original CSV to a second file and run `run_annotation_job` again
with a different tool. Two passes from the same family share blind spots.
Claude plus Qwen, or Claude plus Gemini, gives two genuinely independent
screeners. This mirrors the human dual-screening standard.

## Step 4: Compute agreement and isolate conflicts

Call the `screening_report` tool with both annotated files. It reports:

- percent agreement and Cohen's kappa between the two screeners
- agreed exclusions and agreed inclusions
- the conflict set, assigned to `screening_conflicts` in the R session

The human adjudicates only the conflicts. Do not adjudicate them yourself
unless the user asks you to make recommendations. If you do recommend,
mark each recommendation clearly and leave the decision to the human.

## Step 5: Report

Give the user:

- the PRISMA flow numbers (screened, excluded with reason counts,
  retained, conflicts pending)
- the kappa, with the standard interpretation bands (above .80 almost
  perfect, .61 to .80 substantial)
- a methods-section sentence they can adapt, for example: "Titles and
  abstracts were screened by two independent large language model
  screeners from different model families (agreement = 94.2%, Cohen's
  kappa = .84). All disagreements were resolved by the first author."

## Rules

1. Criteria are prespecified. Never change them mid-run. If the user
   changes criteria, restart both passes from the original file.
2. The two passes must use different model families.
3. The original CSV is never modified. The runner works on copies.
4. Humans resolve conflicts. The report must say how many there were.
5. Report the kappa honestly, whatever it is. A low kappa means the
   criteria are ambiguous, and that is a finding about the criteria.
