---
name: autonomy-boundaries
description: Use whenever executing a multi-step plan, task document, or numbered subtask list in any of fred's repos, and whenever deciding whether to continue to the next step or stop and ask. Codifies the scope-bounded autonomy rule -- the assigned scope is the boundary, not a step count -- that replaces the older "stop and confirm after every single step" protocol. Defines the four continue conditions, the hard stop triggers, and the scope-expansion prohibition that keeps an agent from doing work the user did not ask for.
---

# Autonomy boundaries: scope is the boundary

An agent executing a plan should run **front to back within the scope
it was given**, and stop the moment it would exceed that scope or hits
something the plan did not foresee.

This replaces the older rule -- "execute one step, stop, post a
summary, wait for confirmation, repeat" -- which made the user a
manual scheduler for work they had already approved. Approving a plan
_is_ the confirmation. Re-asking after each step does not add safety;
it adds latency and trains the user to rubber-stamp.

But the old rule existed for a real reason: sub-agents told to
"understand the code" repeatedly decided on their own to start writing
code, committing, and moving on to the next task. **The fix for that is
a hard scope boundary, not a short leash.** A leash slows down correct
work exactly as much as incorrect work. A boundary only stops the
incorrect kind.

## The rule

> **"Do plan X" means all of plan X, front to back, and nothing else.**

Continue to the next step **without asking** while all four hold:

1. **Verification is green.** The repo's mandatory suite passes (see
   `testing-mandate`). A red suite is a full stop, never a "fix it
   while I'm here".
2. **No scope expansion.** Every file you touched is inside the
   assigned scope. Needing a file outside it is a stop.
3. **No unresolved design decision.** The plan already decided every
   type name, signature, and approach. If you would have to _choose_
   rather than _implement_, that is a stop.
4. **Nothing unforeseen.** No pre-existing bug, no wrong assumption in
   the plan, no upstream surprise. The plan describes reality.

If all four hold, keep going. Do not post a summary and wait. Do not
ask "shall I continue?". Finish the scope.

The moment any one fails: **stop, and report.** Not "stop, work around
it, and mention it later".

## Hard stop triggers

Stop immediately and surface to the user when:

- The verification suite fails in a way the plan did not predict.
- The work requires editing a file outside the assigned scope.
- A design decision was left open (or the plan's decision turns out to
  be unimplementable as written).
- A pre-existing bug is found. Report it; do not fix it inline. See
  `agent-orchestration-protocol` for the cleanup-entry convention.
- The plan contradicts the code -- the plan was written against a state
  that no longer exists.
- A step marked `TENTATIVE`, `needs approval`, or equivalent is
  reached. Those markers exist precisely to force a stop.
- A change would weaken a stated invariant, even if tests still pass.
- You are about to do something the user did not ask for because it
  seems obviously beneficial. That is scope creep with good intentions.
  Surface it as a suggestion instead.

## What "and nothing else" forbids

The scope boundary is symmetric: it stops you doing _less_ than asked,
and it stops you doing _more_.

- No opportunistic refactors of code you happened to read.
- No "while I was in there" fixes.
- No tidying unrelated lint warnings.
- No new files -- especially markdown -- outside the plan. See
  `no-summary-documents`.
- No proceeding into the _next_ plan/version because the current one
  finished cleanly.
- No expanding a sub-agent's scope to avoid a round trip.

If something outside scope genuinely needs doing, it is reported as a
finding, and the user (or the orchestrator) decides. The work item is
recorded; it is not silently absorbed.

## Reverting to step-by-step confirmation

Scope-bounded autonomy is the default, but it is not mandatory. The
user can request the older behaviour per session, and it overrides
this skill:

```text
Step-by-step mode: execute one subtask, then stop and report. Wait
for my confirmation before each subsequent subtask.
```

Honour that for the rest of the session. Useful when the plan is
speculative, the blast radius is large, or the user is actively
watching and wants to steer.

The inverse also holds -- if the user says "just do the whole thing,
don't check in with me", that does **not** remove the hard stop
triggers above. Those are safety, not ceremony. An unforeseen problem
still stops the run.

## Reporting when you do stop

A stop is not a failure; it is the protocol working. Report:

1. What was completed (with verification status for each step).
2. Exactly where you stopped and which trigger fired.
3. What you found -- the specific bug, ambiguity, or conflict.
4. Options, if there are several, with a recommendation.

Do not bury the trigger under a summary of the work. Lead with why you
stopped.

## Relationship to the other skills

- `agent-orchestration-protocol` -- how to scope sub-agents so they
  inherit a correct boundary in the first place.
- `plan-decomposition` -- how to write subtasks whose scope is
  unambiguous, so condition 2 is checkable.
- `testing-mandate` -- what "verification is green" means per repo.
- `commit-discipline` -- each step still leaves the tree green and
  committable.

## When to stop and ask

- The assigned scope is itself ambiguous ("clean up the parser"). Get
  it pinned down before starting; an unclear boundary cannot be
  respected.
- The plan's remaining steps depend on a decision the user deferred.
- You have stopped three times on the same plan for related reasons.
  The plan is probably wrong; say so rather than continuing to
  chip at it.
