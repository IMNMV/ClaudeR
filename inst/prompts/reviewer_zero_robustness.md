
---

## Pass 6: Robustness / Specification-Curve Analysis

For the manuscript's PRIMARY claims, test whether the reported conclusions
survive defensible alternative analysis choices. This pass is descriptive:
it maps the specification space, it does not relitigate the authors' choice.

### Step 6a: Select targets

Pick the claims that carry the paper's conclusions -- the headline hypothesis
tests, typically 1-3 claims from the registry. Do not run this pass on
descriptives or manipulation checks. State which claim_ids you selected and
why.

### Step 6b: Enumerate defensible specifications

For each target, list the analysis choices a reasonable expert could have
made differently, grounded in what the data and code actually support:

- Exclusion rules (reported rule, no exclusions, stricter rule)
- Covariate sets (none, reported, full theoretically-motivated set)
- Model family/link where defensible (e.g., Poisson vs. negative binomial)
- Outlier handling (keep, winsorize, remove by stated rule)
- Variable coding/transformations the manuscript mentions or the data invite

Build the grid with `expand.grid`. Cap it at 64 specifications per claim;
if the full crossing is larger, drop the least defensible dimension and say
so in the report. The reported specification MUST be one row of the grid.

### Step 6c: Run the grid in the background

Write ONE self-contained function `run_spec(spec_row)` that loads the data,
applies the choices, fits the model, and returns a one-row data.frame:
`spec_id, estimate, se, ci_low, ci_high, p, n`. Then submit the whole grid
through `execute_r_async` (self-contained code; save the data it needs with
`saveRDS` first, and pass `outputs = c("spec_results")` so the results
data.frame is marshaled back). Poll with `get_async_result`. Wrap each fit
in `tryCatch` so one failing spec records `NA` instead of killing the job.

### Step 6d: Summarize

With `spec_results` in the main session:

```r
spec_results <- spec_results[order(spec_results$estimate), ]
spec_results$rank <- seq_len(nrow(spec_results))
plot(spec_results$rank, spec_results$estimate, pch = 16,
     col = ifelse(spec_results$p < .05, "black", "grey60"),
     xlab = "Specification (ranked)", ylab = "Estimate",
     main = "Specification curve")
segments(spec_results$rank, spec_results$ci_low,
         spec_results$rank, spec_results$ci_high,
         col = ifelse(spec_results$p < .05, "black", "grey70"))
abline(h = 0, lty = 2)
# Mark the reported specification
rep_row <- which(spec_results$is_reported)
points(spec_results$rank[rep_row], spec_results$estimate[rep_row],
       col = "red", pch = 17, cex = 1.4)
```

Report per target claim: median estimate across specs, the range, the
percentage of specs significant at the reported alpha, whether the sign is
stable, and where the reported specification falls in the distribution
(e.g., "reported estimate is at the 92nd percentile of the spec curve").

### Report additions

Add a "Robustness" section to the Final Report with the summary table and
curve for each target claim. State plainly: conclusions that hold across
most of the grid are robust to analytic choice; conclusions that depend on
a narrow region of the grid are fragile, which is a property of the
evidence, not an accusation.
