
---

## Final Step: Manuscript Write-back

The user asked for the audit to be written back into the manuscript as
native Word comments, so each finding can be reviewed and accepted or
dismissed in Word. This step runs ONLY if the manuscript is a `.docx`; for
other formats, state that write-back requires .docx and skip it.

After the Final Report, build an annotations data.frame from the registry
and inject the comments:

```r
flagged <- claim_registry[claim_registry$status %in%
                          c("discrepancy", "rounding", "not_found", "error"), ]

annotations <- data.frame(
  anchor  = flagged$verbatim,
  comment = sprintf("[Reviewer Zero: %s] reported %s; recomputed %s. %s",
                    flagged$status, flagged$reported,
                    flagged$recomputed, flagged$notes),
  stringsAsFactors = FALSE
)

# If a preregistration audit ran, add its non-followed items too:
# anchor = the manuscript text tied to the deviation (NOT the prereg text),
# comment = "[Prereg: <status>] planned: <planned>. <evidence>"

result <- ClaudeR::annotate_manuscript(
  "path_to_manuscript.docx",
  annotations,
  author = "Reviewer Zero"
)
print(result$unmatched)
```

Rules:
- Anchors must be verbatim substrings of the manuscript text -- reuse the
  `verbatim` field, which Pass 1 already proved exists via `grepl()`.
- Keep each comment self-contained: status, reported value, recomputed
  value, and where the recomputation came from (script and line).
- The tool writes to `<name>_annotated.docx` and never touches the
  original. Report the output path and any unmatched anchors; retry
  unmatched ones with a shorter distinctive substring of the same claim.
- Comments are for findings, not praise. Do not annotate claims whose
  status is "match".
