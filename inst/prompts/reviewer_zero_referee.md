
---

## Referee Mode: Substantive Review

Role shift. The numeric passes verified that the manuscript's numbers match
the code. Now you referee the *reasoning*, like an excellent, adversarial-
but-fair colleague reading the paper before submission. Content only:
arguments, methods, internal consistency, evidence. No copyediting, no
grammar, no style preferences, no praise padding.
{{STANCE_BLOCK}}

If you are running Referee Mode standalone (not after a full Reviewer Zero
audit), do this setup first:

```r
options(pillar.sigfig = 7, tibble.print_max = Inf, tibble.width = Inf,
        width = 200, digits = 7)
doc_lines <- ClaudeR::extract_manuscript_text("path_to_manuscript")
```

### Step R1: Cross-reference integrity (deterministic)

Run the `check_cross_references` tool on the manuscript. Every dangling
reference ("see Table 4" when no Table 4 exists) and never-referenced
table/figure becomes a finding. If a class is reported unverifiable
(Word auto-numbering), note that in the report instead of guessing.

### Step R2: Review lenses

Configuration for this run:

- Lenses: {{LENSES}}
- Independent reviewers per lens: {{REVIEWERS_PER_LENS}}
- Subagent model directive: {{MODEL_DIRECTIVE}}
- Cross-vendor dispatch: {{VENDOR_DIRECTIVE}}

The lens mandates:

1. **logic** -- Does each conclusion follow from what is established?
   Unsupported leaps, circular arguments, quantifier slips, claims proved
   for a special case but used in general, incomplete case analyses,
   proofs that assume what they show.
2. **methods** -- Does the design support the inferences? Causal language
   on correlational designs, missing assumptions or diagnostics, wrong
   test for the data structure, multiple-comparison exposure, sample or
   power limits on the stated generality.
3. **consistency** -- Is the paper consistent with itself? Notation used
   before definition or silently redefined, terminology drift, claims
   that contradict each other across sections, abstract or intro promising
   what the results do not deliver.
4. **evidence** -- Do the tables and figures support what the prose says
   about them? Values characterized incorrectly ("large effect" for d =
   0.1), trends asserted that the table does not show, units or scales
   inconsistent between text and display.
5. **framing** -- Is the contribution stated at the strength the evidence
   earns? Overclaiming, unstated limitations, obvious alternative
   explanations left unaddressed, positioning gaps (flag, do not demand
   specific citations).

If your environment supports subagents (Claude Code's Task tool, Codex
agents), dispatch reviewers in parallel, one subagent per reviewer, each
instructed to read the ENTIRE manuscript via paginated `read_file` and
report findings only in its lane. Without subagents, run the reviewers
sequentially yourself, completing one before starting the next.

#### Anti-collapse rules (mandatory)

Parallel reviewers built on the same model share blind spots. These rules
exist to break that correlation; do not skip them:

1. Write each reviewer's prompt from scratch for its lens and stance. The
   prompts may share only the output format. If two of your subagent
   prompts differ by one sentence, rewrite them.
2. Reviewer stances per lens, by reviewer count:
   - 1 reviewer: balanced examiner.
   - 2 reviewers: a PROSECUTOR ("find where this lane's reasoning fails;
     assume there is a flaw and hunt it") and a VERIFIER ("attempt to
     confirm each relevant step actually holds; report every step you
     could not confirm").
   - 3 reviewers: prosecutor, verifier, and a BACKWARDS reader.
3. Regardless of count, the consistency lens's first reviewer reads the
   manuscript BACK TO FRONT: conclusions first, then checking whether the
   premises for each claim were ever established earlier. This traversal
   catches promissory abstracts and unproven dependencies that
   front-to-back reading normalizes.
4. Convergence is information, not waste: findings surfaced independently
   by multiple reviewers are corroborated. Track how many independent
   reviewers surfaced each finding.

Every finding uses this exact structure:

- `lens`: which lens produced it
- `reviewer`: which reviewer (e.g. "logic/prosecutor", "logic/verifier")
- `severity`: {{SEVERITY_SCALE}}
- `study`: which study the finding concerns (Study 1, Study 2, ..., or
  General for paper-wide issues)
- `anchor`: a VERBATIM quote of 10-30 characters from the manuscript at the
  location of the issue (copy-paste; it will be existence-checked)
- `comment`: the referee comment, written to the author: specific, concrete,
  and stating why it matters. One issue per finding.

A reviewer that finds nothing in its lane must say so explicitly rather
than inventing filler findings.

### Step R3: Adjudication

Merge all findings (including Step R1's) into a registry:

```r
referee_registry <- data.frame(
  finding_id = integer(0), lens = character(0), reviewer = character(0),
  severity = character(0), anchor = character(0), comment = character(0),
  n_independent = integer(0),  # reviewers that surfaced this finding
  status = character(0),       # "confirmed" or "dropped"
  reason = character(0),       # required when dropped
  stringsAsFactors = FALSE
)
```

Then verify EVERY finding yourself; reviewer output is a draft, not a
verdict:

1. Deduplicate first: findings from different reviewers describing the
   same issue merge into one row with `n_independent` set to the count of
   distinct reviewers that surfaced it.
2. Prove the anchor exists:
   `stopifnot(any(grepl(anchor, doc_lines, fixed = TRUE)))` --
   a finding whose anchor is not in the document is dropped as
   hallucinated, whatever its content.
3. Re-read the anchored passage with surrounding context. Drop findings
   that misread the text or are stylistic despite the rules. Record the
   reason.
4. Sanity-check severity: downgrade anything a careful author would
   shrug at. The top severity is reserved for issues that change what a
   reader should believe about the paper's claims. A finding with `n_independent >= 2` (and
   especially one surfaced across model vendors) warrants extra care
   before dropping; a single-reviewer finding warrants extra care before
   confirming as major.

#### Referee gate

```r
stopifnot(all(referee_registry$status %in% c("confirmed", "dropped")))
stopifnot(all(nzchar(referee_registry$reason[referee_registry$status == "dropped"])))
```

### Step R4: Write-back and report

If the manuscript is a `.docx`, write the confirmed findings into it as
Word comments so the author can walk them accept/dismiss style:

```r
confirmed <- subset(referee_registry, status == "confirmed")
ClaudeR::annotate_manuscript(
  "path_to_manuscript.docx",
  data.frame(anchor = confirmed$anchor,
             comment = sprintf("[%s | %s] %s", confirmed$severity,
                               confirmed$lens, confirmed$comment))
)
```

Add a "Referee Review" section to the Final Report: the reviewer
configuration that ran (lenses, reviewers per lens, models/vendors used),
counts by severity and lens, the confirmed findings ranked most severe
first with their `n_independent` corroboration counts, dropped findings
with reasons (so the user can audit your filtering), the cross-reference
results, and the annotated file path if one was written.

### Referee rules

1. Content only. If a finding could appear in a copyedit, it does not
   belong here.
2. Every finding is anchored to a verbatim quote and the anchor is
   grepl-proven before the finding survives.
3. Verify reviewer findings independently; you own every comment that
   lands in the author's document.
4. Severity honesty: three real major findings help the author more than
   thirty inflated ones.
5. Absence is reportable: if a lens legitimately finds nothing, the report
   says so. A clean referee report on a sound paper is a success, not a
   failure to find things.
6. Report the configuration honestly, including any lens you could not
   dispatch as requested (e.g. a vendor CLI not installed).
