---
name: plan-sequencing-discipline
description: Use when maintaining a numbered set of plan/roadmap documents over time in any of fred's repos -- adding a plan, renumbering one, declaring a dependency between plans, changing a plan's status field, marking one complete when its PR merges, or deciding whether two plans may run concurrently. Codifies the number-is-the-execution-order rule, the contiguous-completed-prefix invariant, the no-forward-dependencies rule, freeze-on-start, the merge-is-the-completion-trigger rule, and the index-must-not-drift rule. Distinct from plan-decomposition, which covers turning ONE plan into subtasks.
---

# Plan sequencing discipline

`plan-decomposition` covers turning **one** plan into subtasks. This
skill covers the **set** of plans: how they are ordered, how
dependencies between them are constrained, and how their status is kept
honest as work lands.

Both failure modes this prevents have actually happened in fred's repos
and are recorded below. They are bookkeeping failures, not code
failures, which is exactly why they go unnoticed until the plan is
lying about the state of the project.

## The number is the execution order

A plan's number **is** its position in the sequence. There is no
separate phase concept, no ordering document beside the numbering, and
no second source of truth.

A repo that layered a Phase A / Phase B split on top of its numbering
produced the order `07`=A, `08`=B, `09`=A, `10`=A, `11`=B -- document
order diverged from execution order, and the sequence became unreadable
without opening every document. An external ordering file is the same
mistake relocated: a second document drifts from the numbering exactly
as phase labels did.

## The completed set is a contiguous prefix

A `complete` plan may never sit above a plan that is not complete.

This is **deliberately weaker** than strict serial execution. It
permits concurrent work on adjacent incomplete plans, and that weakness
is the point -- strict serial ordering would forbid the parallel
sub-agent execution that `parallel-work-isolation` exists to enable.

Read precisely what it permits, though: concurrent **work**, not
concurrent **completion**. Since merge is the completion trigger,
merging a higher-numbered plan while a lower one is unfinished breaks
this invariant immediately. The merge barrier that follows from that is
spelled out under "Deciding whether two plans may run concurrently".

What it forbids is a completed plan sitting above an unstarted or
in-progress one. When that happens the numbering no longer describes
execution order, and it must be corrected rather than explained.

Note the interaction: this invariant breaks *silently* if someone
forgets to flip a status at merge time. The plan file and reality
disagree, the prefix looks intact, and nothing complains.

## No forward dependencies

Every dependency a plan declares must name a **strictly lower** number.

A forward dependency means the sequence is not a valid topological
order, and a graph that is not a valid topological order can deadlock.
This is not hypothetical. One repo reached a state where plan 11 blocked
on plan 8, plan 8 needed a working implementation that depended on plan
12, and plan 12 was blocked on plan 8 going green. **No legal first
move into implementation existed.** Every rule in this skill exists to
make that mechanically impossible rather than merely discouraged.

If a plan genuinely needs something from a higher-numbered plan, the
numbering is wrong, or the work is split at the wrong boundary. Fix the
order; do not add the edge.

## A number freezes the moment work starts

Once a plan goes active (branch created, first commit made), its number
is immutable. Renumbering only ever touches plans that have **never**
started -- by definition those carry no branch and no commit pointing at
them.

A repo that renumbered twice in one day without this rule accumulated
77 dangling cross-references that had to be found and fixed by hand.

The same applies to subtask IDs: a subtask is `<its own plan's
number>.<n>`, never another plan's prefix and never a letter-suffixed
variant of one. Two real bugs came from violating this -- a plan
numbered its subtasks against a different plan's old number, and
another numbered its subtasks against a temporary staging document. The
result was one subtask ID naming two unrelated pieces of work in two
different files, neither of which lived in the document actually
carrying that number.

## The merge is the completion trigger

Status moves in one direction. The exact vocabulary is per-repo, but
the shape is:

```text
stub/planned -> in progress -> pending merge -> complete
```

**The defining event for `complete` is the PR merging**, not the last
subtask commit and not the branch going green. Advance the status in
the same change that records the merge.

This is the transition that gets forgotten, for three compounding
reasons all observed in practice:

1. **The trunk lags the work.** A long-running integration branch can
   be dozens of commits ahead of the mainline, so "is it merged?" has
   two answers depending on which branch is meant. Answer it about the
   plan's own target branch.
2. **Status is often maintained in more than one place** and only one
   gets updated. See the next section.
3. **The workflow updates the plan at task-completion time on the
   branch, and has no step that fires at merge time** -- so statuses
   freeze at whatever they were when the branch closed.

If a repo's workflow has no merge-time step, that is the bug. Add one.

## An index and its detail documents must not drift

When a top-level index (a roadmap table, a master plan) restates facts
that also live in the individual plan documents, both are updated **in
the same commit**. Always.

This is not theoretical either: one index drifted within an hour of
being rewritten, because a plan gained a dependency entry and the
index row was not updated alongside it. Another repo tracked status in
two tables -- a summary column and a completion-date table -- and
routinely showed a completion date next to a status of "pending merge".

Prefer a mechanical check over vigilance. If the repo has a
plan-linting command, run it before claiming any plan work is done; if
it does not, the duplication is a standing liability and worth
surfacing.

## Deciding whether two plans may run concurrently

`parallel-work-isolation` gives the code-level test: disjoint files,
disjoint behaviour, no shared-type edits, independently valid
verification. This skill adds the **plan-graph-level** test, and both
must pass:

- Neither plan depends on the other (directly or transitively).
- **Merges are ordered lowest-number-first.** Concurrent *work* is
  allowed; concurrent *completion* is not.

That second condition is a hard barrier, not a prediction. Because merge
is the completion trigger, letting a higher-numbered plan merge first
makes it `complete` while a lower-numbered one is not -- which violates
the prefix invariant directly.

State the barrier from the invariant, not from the concurrency:

> **A plan may merge only when every lower-numbered plan is already
> `complete`.**

Do not weaken this to "every lower-numbered plan it was racing".
Whether two plans overlapped in time is irrelevant to the invariant --
the prefix is broken by *any* incomplete lower plan, including one that
never started and one nobody is working on. Plan 31 merging while plan 5
sits at `stub` is the same violation as plan 31 beating plan 30 in a
race.

If a lower plan turns out to need another week, the higher one waits at
`pending merge`. If that wait is unacceptable, renumber **before** work
starts -- once either plan is active its number is frozen and this
option is gone.

Two plans that are adjacent, mutually independent, and forward-clean
are eligible for concurrent execution under that barrier. Eligible is
not advisable on its own: apply the code-level test from
`parallel-work-isolation` before actually running them in parallel.

Note what this costs. The barrier serialises the *merge*, not the work,
so the parallelism is real but the payoff is smaller than it looks -- a
finished higher plan sitting at `pending merge` is capital tied up, and
it still needs a rebase after the lower plan lands. If the merge order
is going to be a problem, renumbering before work starts is cheaper
than a long-held barrier.

## Hard rules

- Do NOT introduce a second ordering source (a phase label, an
  ordering document, a priority field that overrides the number).
- Do NOT add a dependency pointing at a higher number. Re-order
  instead.
- Do NOT renumber a plan that has started.
- Do NOT number a subtask under any plan but its own.
- Do NOT leave a plan at `pending merge` after its PR has merged.
- Do NOT merge a plan while **any** lower-numbered plan is incomplete,
  whether or not the two ran concurrently, and whether or not the lower
  one has started. Hold at `pending merge`.
- Do NOT update an index without updating the plan document in the same
  commit, or vice versa.

## When to stop and ask

- The correct fix is renumbering a plan that has already started.
  That is prohibited above; surface the conflict rather than choosing
  between two bad options.
- A plan genuinely appears to need a forward dependency. Either the
  split is at the wrong boundary or the order is wrong -- both are
  design decisions, not bookkeeping.
- The completed set is already not a contiguous prefix when you arrive.
  Report it; do not silently renumber live work to repair the
  invariant.
- A repo's status vocabulary does not map onto the one-directional
  shape above (e.g. it has a `blocked` or `withdrawn` state). Ask how
  that state interacts with the prefix invariant rather than assuming.
- A finished plan is stuck at `pending merge` behind a lower-numbered
  plan that is stalled, abandoned, or much larger than estimated. The
  legitimate options -- wait, split the lower plan so its blocking part
  lands, or accept a documented exception -- are all decisions for the
  user. Do not merge out of order to unblock yourself, and do not
  renumber started work to dodge the barrier.
