# Multi-Agent Coordination Protocol (v2)

You are one of multiple AI agents sharing an RStudio session via ClaudeR.
Coordination runs on a typed, append-only event log shared by every agent
(and by the Python bridge, so messaging works even while R is busy). It
survives R restarts. Nothing you read requires mutating shared state, so
you can never clobber another agent's writes.

Two ways to use it, same log underneath:

- MCP tools (preferred): `send_message`, `check_messages`,
  `wait_for_message`, `coordination_roster`
- R functions via execute_r: `cr_send()`, `cr_inbox()`, `cr_ack()`,
  `cr_fact()`/`cr_facts()`, `cr_claim()`/`cr_release()`/`cr_done()`,
  `cr_roster()`, `propose_plan()`, `confirm_agreement()`,
  `consensus_status()`

---

## Phase 0: Check in

1. Identity FIRST, before any code execution or message. Two cases:
   - You have your own MCP connection (the normal case: one CLI session per
     agent): call `set_agent_name` with your working name (e.g.
     "Claude-Stasis") and reuse the same name every session. For a permanent
     name, set the CLAUDER_AGENT_ID environment variable in your MCP
     registration.
   - You SHARE one MCP connection with other agents or personas (subagents,
     multiple conversations on one registration): do NOT use
     `set_agent_name`. It renames the whole connection, so personas end up
     renaming each other in a tug-of-war. Instead pass `as_agent = "YourName"`
     on every `send_message`, `check_messages`, and `wait_for_message` call;
     each name keeps its own read cursor. The agent intro tells you where
     your current id came from; if it is a name you did not choose, you are
     probably on a shared connection. The bridge enforces this: a second
     set_agent_name with a different name is refused, and every send
     confirmation echoes the name it was sent as, so check it.
2. `coordination_roster` -- who is here, who is stale.
3. `check_messages` -- read everything unread addressed to you or to all.
4. `consensus_status()` (via execute_r) -- is there a plan already, and is
   it approved?

If a plan exists and is approved, skip negotiation: claim an open task and
work.

## Phase 1: Typed messages, not prose conventions

Anything another agent must DETECT goes in a typed event, never in prose:

- Signal readiness: `send_message` with `type = "signal"`,
  `body = {"name": "KIT_READY", "tile": "3094,3493"}`
- Ask a question: `type = "question"`, and reply with `reply_to` set to the
  question's event id so threads are explicit.
- Prose is for context and reasoning; signals are for triggers. Never make
  another agent grep your sentences.

Shared state (who owns which account, coordinates, phase markers) goes in
facts, not chat: `cr_fact("mule_tile", "3094,3493")`, read back with
`cr_facts()`. Latest write wins; facts are queryable, prose is not.

Delivery guarantees: coordination logs are keyed by R session. If a
coordination call returns FAILED because no live R session exists, nothing
was written; restart the ClaudeR addin, reconnect, and resend. If a reply
starts with a NOTE that the connection re-bound to a different live
session, your earlier sends may sit in the old session's log unseen, so
resend anything the other agents did not acknowledge.

## Phase 2: The plan and the consensus gate

One agent proposes the division of labor:

```r
propose_plan("alpha: EDA and diagnostics. beta: models and reporting.
             Handoff after cleaning via signal CLEAN_READY.")
```

Proposing ARMS the consensus gate. From that moment, every code-execution
response in the session carries this banner:

```
AGREEMENT NOT REACHED PLEASE STOP AND CONFIRM YOU AND YOUR PARTNER BOTH AGREE BEFORE CONTINUING
IF YOU BOTH AGREE YOU MUST BOTH WRITE 'I CONFIRM I HAVE READ THEIR SUGGESTION AND WE HAVE BOTH REACHED AN AGREEMENT TO MOVE FORWARD'
DO NOT CONFIRM THIS IF IT IS NOT TRUE.
```

The banner means exactly what it says. Read your partner's latest position
(`check_messages`). If you want changes, reply with a counter-proposal
(`propose_plan()` again re-arms with the new text). When, and only when,
you have read their suggestion and genuinely agree, run:

```r
confirm_agreement("I CONFIRM I HAVE READ THEIR SUGGESTION AND WE HAVE BOTH REACHED AN AGREEMENT TO MOVE FORWARD")
```

The sentence must match verbatim; anything else is rejected. Both agents
(the proposer too) must confirm. When the required number of distinct
agents have confirmed, the plan is marked APPROVED, the banner stops, and
work may begin. Never write the confirmation if it is not true: the gate
exists because agents have talked past each other and started conflicting
work while believing they agreed.

## Phase 3: Claim before you work

Tasks are lease-based claims, not rows you edit:

```r
cr_claim("fit_models", lease_s = 1800)   # TRUE, or FALSE + current holder
cr_done("fit_models", note = "3 models fit, saved to models/")
```

A claim held by another agent blocks yours until it expires or they
release. Renew a long task by re-claiming before your lease runs out.
Never work on a task whose claim you could not obtain.

## Phase 4: Working

- Start every code block with `# [your-agent-id] purpose` so the shared
  session log reads cleanly.
- Prefix temporary objects with your initial; final shared objects get
  clean names.
- Build on your partner's objects; never silently overwrite them. Disagree
  by sending a `type = "message"` with your concern and running your
  alternative alongside.

## Phase 5: Rendezvous and handoffs

For anything requiring co-presence or strict ordering, block on the event
instead of polling:

```
wait_for_message(timeout_s = 600, from_agent = "beta", type = "signal")
```

This returns the instant the matching event lands, while your partner keeps
working (waiting never touches the R session). On handoff, send a signal
naming the objects produced: `body = {"name": "CLEAN_READY",
"objects": "clean_data, eda_summary"}`.

## Phase 6: Presence

Every write stamps your presence automatically. If you have nothing to say
for a long stretch, `cr_ping()` keeps you off the stale list. Check
`coordination_roster` before assuming a silent partner is gone; check
their last event before assuming they are alive.

---

## Rules

1. Check the roster, your inbox, and consensus_status before doing anything.
2. Machine-checkable content travels as typed signals or facts, never prose.
3. The consensus sentence is written verbatim or not at all, and never
   when untrue. The banner does not stop until everyone has confirmed.
4. Claim before working; release or complete what you claimed.
5. Reply with reply_to so threads are explicit.
6. Use wait_for_message for rendezvous instead of poll-and-hope.
7. Cross-check your partner's work when relevant; the goal is an analysis
   better than either of you alone.
