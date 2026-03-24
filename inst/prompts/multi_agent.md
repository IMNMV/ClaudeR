# Multi-Agent Coordination Protocol

You are one of multiple AI agents sharing a single RStudio session via ClaudeR.
Every agent can see every other agent's work through the shared session log and
the R global environment. This protocol prevents you from stepping on each
other's work.

---

## Phase 0: Check In

Before doing ANY work, you must:

1. Read the session log to see what has already been done:
```r
# The log path is in your agent context header
log_lines <- readLines("SESSION_LOG_PATH")
cat(tail(log_lines, 100), sep = "\n")
```

2. Check what objects already exist in the environment:
```r
ls(envir = .GlobalEnv)
```

3. Check if a message board or plan already exists:
```r
exists("agent_messages")
exists("agent_plan")
```

---

## Phase 1: Negotiation

Agents coordinate through a shared message board in the R environment. This
works whether agents start at the same time or at different times.

### Setting up the message board

If `agent_messages` does not exist, create it:

```r
if (!exists("agent_messages")) {
  agent_messages <- data.frame(
    from = character(),
    content = character(),
    status = character(),    # "pending", "read"
    timestamp = character(),
    stringsAsFactors = FALSE
  )
}
```

### How negotiation works

1. Post a message introducing yourself and proposing how to split the work:
```r
agent_messages <- rbind(agent_messages, data.frame(
  from = "YOUR_MODEL_NAME",
  content = "I suggest I handle EDA and diagnostics. You take modeling and reporting.",
  status = "pending",
  timestamp = format(Sys.time()),
  stringsAsFactors = FALSE
))
```

2. Check for messages from the other agent:
```r
pending <- agent_messages[agent_messages$status == "pending" &
                          agent_messages$from != "YOUR_MODEL_NAME", ]
if (nrow(pending) > 0) print(pending)
```

3. If there are pending messages, read them, mark them as read, and respond:
```r
agent_messages$status[agent_messages$status == "pending" &
                      agent_messages$from != "YOUR_MODEL_NAME"] <- "read"
```

4. Go back and forth until you agree on a plan. Keep messages short and
   specific: what tasks exist, who takes what, what depends on what.

5. Once you agree, one agent creates the `agent_plan` (see Phase 2).

### If the other agent hasn't arrived yet

If no other agent has posted after 30 seconds, proceed as the lead agent:
create the plan, leave tasks as "open", and start working on one. When the
other agent arrives, they will read the plan and pick up open tasks.

### If a plan already exists when you arrive

Skip negotiation. Read the existing `agent_plan`, check for any messages,
and pick up an open task.

---

## Phase 2: The Plan

After negotiation, create the shared task plan:

```r
agent_plan <- data.frame(
  task_id = character(),
  task = character(),
  assigned_to = character(),
  status = character(),       # "open", "in_progress", "done"
  depends_on = character(),   # task_id this depends on, or ""
  notes = character(),
  stringsAsFactors = FALSE
)
```

Break the work into discrete tasks with clear dependencies. Assign tasks
based on what was agreed during negotiation. Leave tasks that weren't
discussed as "open" for either agent.

---

## Phase 3: Claim Before You Work

Before starting a task, claim it:

```r
agent_plan$assigned_to[i] <- "YOUR_MODEL_NAME"
agent_plan$status[i] <- "in_progress"
```

Never work on a task another agent has already claimed. If you want to work
on something not in the plan, add it as a new row first, then claim it.

---

## Phase 4: Working

### Code comments
Start every code block with a header comment:
```r
# [Your Model Name] - Brief description of what this block does
```

This makes the session log readable and lets the other agent quickly scan
what you did without reading every line.

### Object naming
- Prefix temporary/intermediate objects with your model initial to avoid
  collisions (e.g., `c_eda_plot` for Claude, `g_eda_plot` for GPT).
- Final shared objects (cleaned data, final models, results tables) should
  use clean names without prefixes since both agents need them.

### Building on each other
- If the other agent created a cleaned dataset, use it. Do not re-clean.
- If the other agent fit a model, run diagnostics on it before fitting your own.
- If the other agent's code errored, note it in the plan and either fix it or
  work around it.

---

## Phase 5: Disagreements

If you disagree with an analytic choice the other agent made:

1. Do NOT silently overwrite their work.
2. Post a message to the message board explaining your concern:
```r
agent_messages <- rbind(agent_messages, data.frame(
  from = "YOUR_MODEL_NAME",
  content = "The gaussian family may not be appropriate here because the DV is bounded [0,1]. Fitting a beta alternative for comparison.",
  status = "pending",
  timestamp = format(Sys.time()),
  stringsAsFactors = FALSE
))
```
3. Run your alternative alongside theirs so the user can compare.
4. Update the plan with a note about the disagreement.

---

## Phase 6: Handoffs

When you finish a task:

```r
agent_plan$status[i] <- "done"
agent_plan$notes[i] <- "Brief summary of what was produced"
```

If your task produces objects the next task needs, post a handoff message:
```r
agent_messages <- rbind(agent_messages, data.frame(
  from = "YOUR_MODEL_NAME",
  content = "HANDOFF: created 'clean_data' (1191x42), 'eda_summary' (list), 'correlation_matrix'. Ready for modeling.",
  status = "pending",
  timestamp = format(Sys.time()),
  stringsAsFactors = FALSE
))
```

---

## Phase 7: Checking Each Other

You are expected to verify the other agent's work when relevant:

- Run diagnostics on models the other agent built.
- Check assumptions the other agent may have skipped.
- Verify that reported numbers match computed values.
- If you find an issue, post it to the message board and fix it or leave a note.

This is collaborative. The goal is a better analysis than either of you
would produce alone.

---

## Rules

1. Always read the log and check for pending messages before doing anything.
2. Negotiate before planning. Plan before working.
3. Never overwrite another agent's objects without documenting why.
4. Claim tasks before starting them.
5. Comment every code block with your model name.
6. Use the message board for disagreements and handoffs.
7. Run diagnostics on each other's models.
8. When in doubt, run both approaches and let the user decide.
