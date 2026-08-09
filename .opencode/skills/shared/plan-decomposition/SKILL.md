---
name: plan-decomposition
description: Use when turning a plan, roadmap version, epic, or feature request into implementable subtasks in any of fred's repos -- especially when activating a stub plan or fleshing out a task list for sub-agent execution. Codifies just-in-time planning (do not decompose far-future work), the orchestrator-decomposes / implementer-executes / orchestrator-reviews division of labour, the five-part subtask contract, and the decomposition heuristics that make subtasks parallel-safe.
---

# Plan decomposition

This skill governs **planning time**: turning a goal into subtasks that
a sub-agent can execute without judgement calls. It is the companion to
`agent-orchestration-protocol`, which governs **execution time**.

Scope boundary: this skill is about **one** plan's internals. For the
plan **set** -- numbering as execution order, dependencies between
plans, the contiguous-completed-prefix invariant, status transitions at
merge time, and keeping a roadmap index in sync -- load
`plan-sequencing-discipline`.

## Decompose just in time, against real code

Plan documents should be written in two tiers:

- **Imminently-activated work** carries a full per-subtask breakdown,
  written against the _current_ codebase.
- **Far-term work** stays an **enriched stub**: goal, task summary,
  every durable design decision already made, open questions tagged
  "decide at activation" -- but **no subtask decomposition**.

The reasons are economic and correctness-driven:

1. A breakdown written far in advance is a guess about a codebase that
   will have changed underneath it. It rots.
2. Decomposition is the expensive orchestration work. Doing it early
   means paying for it, watching it go stale, and paying again to
   re-validate at activation.
3. A plan should crystallise a stable understanding, not lead it.

**Durable decisions are recorded; perishable breakdowns are deferred.**
When a real design decision gets made in discussion -- an invariant, a
dependency cut, a chosen library -- write it into the stub now. Do not
invent subtask lists for work that is not next.

## Activation: one dedicated session

When work moves from stub to active:

1. **Read first.** The plan, its dependencies, and -- critically -- the
   _current code_ it will touch. Map the real seams, not remembered
   ones.
2. **Resolve open questions** with the user. The stub's "decide at
   activation" list is the agenda. Do not silently pick answers.
3. **Decompose** into subtasks (shape below) against the seams found in
   step 1.
4. **Write the breakdown into the plan document**, replacing the stub
   body.
5. **Then** begin execution under `agent-orchestration-protocol`.

Activation planning is orchestration, not implementation. Do not begin
implementing in the same breath as decomposing.

## Division of labour

- **Orchestrator** (the expensive model): reads code, decomposes,
  writes subtasks, sequences them, reviews output, makes every
  architectural call.
- **Implementer** (the cheap model): executes one tightly-scoped
  subtask per invocation, with **no architectural latitude**.
- **Orchestrator reviews**: every implementation subtask gets a
  CODE-REVIEW pass before acceptance.

The implementer fills in the body. It never chooses the shape.

## When a subtask is correctly scoped

All five must hold:

1. **Single concern.** One logical change. If the description needs
   "and also", split it.
2. **Explicit file scope.** The exact files it may touch are named. No
   "and related files".
3. **No open design decisions.** Every type name, variant, signature,
   and approach is already decided and written into the subtask. If the
   implementer would have to _choose_, decomposition is incomplete.
4. **Self-contained verification.** The subtask names the exact
   commands that prove it correct, and leaves the repo's suite green --
   the `commit-discipline` invariant.
5. **Bounded.** Roughly one focused implementation pass. If it spans
   many files across module boundaries or needs judgement mid-stream,
   it belongs to the orchestrator or needs splitting.

## Subtask template

```text
#### NN.M -- <single-concern title>

Scope: <exact file list>

What: <the one change, with concrete type/function names already
chosen -- not "design a way to ...">

Deliverable: <the code + the tests that prove it>

Verification: <the repo's exact commands, plus any subtask-specific test>

Prohibitions: do NOT touch files outside scope; do NOT decide
<the thing already decided above>; do NOT proceed to NN.(M+1).

Stop: report files changed + verification results; await review.
```

The plan-doc subtask and the spawned sub-agent prompt are two views of
the same contract. Keep them identical in substance.

## Decomposition heuristics

- **Audit before implement.** When current behaviour is ambiguous, the
  first subtask is a READ-ONLY audit that resolves the ambiguity and
  feeds the implementation subtasks. Do not fold the audit into the
  first implementation subtask.
- **Foundation before features.** If several subtasks each need to add
  to a shared type, land all those shells in one foundation subtask
  first. See `parallel-work-isolation` -- this is what makes the rest
  parallel-safe.
- **Types before behaviour before presentation.** Add the typed state,
  then the logic that maintains it, then the transport, then the
  rendering. Each is its own subtask, in that order.
- **Cross-cutting checklists get their own subtask.** Wiring that has a
  known silent-failure mode (a config option that must be registered in
  several places) is never bolted onto a feature subtask.
- **Documentation updates that are mandatory get a subtask**, not a
  hopeful mention in another subtask's deliverable.
- **Benchmarks**: if the work touches a benchmarked hot path, a
  before/after capture subtask is mandatory. See
  `performance-benchmarks`.

## Decompose for parallelism deliberately

When the work will run as parallel workstreams, decomposition is what
makes that safe. Before declaring subtasks parallel, check them against
the independence tests in `parallel-work-isolation`: disjoint files,
disjoint behaviour, no shared-type edits, independently valid
verification.

Write the execution model into the plan document itself -- which
subtasks may run concurrently, which are strictly sequenced, and the
branch topology. An execution model that lives only in the
orchestrator's head is lost at the end of the session and re-derived
(differently) next time.

## Hard rules

- Do NOT decompose work that is not being activated now.
- Do NOT begin implementation in the same breath as decomposition.
  Decompose, get sign-off, then execute.
- Do NOT let a subtask carry an unresolved design decision into the
  implementer. That choice belongs to the orchestrator.
- Do NOT write subtasks against remembered code. Re-read the seams; the
  codebase moved.
- Do NOT renumber subtasks when one is withdrawn or deferred. Keep the
  number and mark it, so the decision is not re-litigated by the next
  reader.

## When to stop and ask

- An open question has no obvious answer and the user has not weighed
  in. That is the activation conversation.
- The external spec being targeted is unstable. Do not decompose
  against a moving target.
- Decomposition reveals the work is far larger than its estimate. Stop
  and re-scope before writing twenty subtasks.
- You are tempted to flesh out the _next_ chunk of work while you are
  here. Don't. One activation per session.
