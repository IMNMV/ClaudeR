
---

## Pass 5: Preregistration Deviation Audit

A preregistration file was provided: `{{PREREG_PATH}}`

Your job in this pass is to compare what was *planned* against what was
*executed and reported*, using the claim registry and recomputation results
from Passes 1-3 as the evidence base. You are not judging whether deviations
were reasonable. You are producing a complete, neutral inventory of them.

### Step 5a: Extract the plan

Read the preregistration with `read_file`, paginated (~50 lines at a time),
exactly as you did for the manuscript. Build a registry:

```r
prereg_registry <- data.frame(
  item_id    = character(),
  category   = character(),  # hypothesis, sample, exclusion, variable, model, inference, other
  planned    = character(),  # what the prereg commits to (concise)
  verbatim   = character(),  # exact quote from the prereg
  line_start = integer(),
  line_end   = integer(),
  status     = character(),  # set in 5b
  evidence   = character(),  # set in 5b
  stringsAsFactors = FALSE
)
```

Extract every commitment: hypotheses and their directions, target N and
stopping rule, exclusion criteria, variable definitions and transformations,
model specifications (DV, predictors, covariates, family, random effects),
inference criteria (alpha, corrections, one/two-tailed), and planned
robustness or secondary analyses. Prove each verbatim quote with
`grepl(..., fixed = TRUE)` against the prereg lines, as in Pass 1.

### Step 5b: Classify each item

For every row of `prereg_registry`, gather evidence from the manuscript
claim registry, the code (`search_project_code`), and your Pass 3
recomputations, then set `status` to exactly one of:

- `"followed"` -- executed as planned.
- `"deviation_disclosed"` -- executed differently, and the manuscript
  acknowledges the change.
- `"deviation_undisclosed"` -- executed differently with no acknowledgment.
  Quote both the plan and the execution in `evidence`.
- `"not_executed"` -- planned but absent from both manuscript and code.
- `"unverifiable"` -- cannot be determined from the available materials.

Record the supporting file/line references in `evidence` for every non-
`followed` row.

### Step 5c: Exploratory additions

List substantive analyses that appear in the manuscript but not in the
preregistration (new outcomes, new models, new subgroups). These are not
deviations; they are exploratory analyses. Flag any that the manuscript
presents as confirmatory (e.g., reported alongside preregistered tests with
no "exploratory" label).

### Gate

```r
unclassified <- sum(prereg_registry$status == "" | is.na(prereg_registry$status))
stopifnot(unclassified == 0)
```

### Report additions

Add a "Preregistration Audit" section to the Final Report:
- Counts by status, then every non-`followed` item with plan vs. execution
  and file/line evidence
- The exploratory-additions list
- Do NOT editorialize about whether deviations were justified; report them.
