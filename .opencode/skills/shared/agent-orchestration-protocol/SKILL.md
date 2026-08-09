---
name: agent-orchestration-protocol
description: Use whenever about to spawn sub-agents to decompose a task in any of fred's repos. Codifies the mandatory action-class scoping protocol for sub-agent prompts -- READ-ONLY, CODE-REVIEW, IMPLEMENTATION, COMMIT -- with explicit scope, deliverable, prohibitions, and stop condition in every spawned prompt. Also covers the pre-existing-bug cleanup-entry convention and orchestrator-level stop conditions. Ignore this and sub-agents go off-script.
---

# Sub-agent orchestrator protocol

When acting as an orchestrator -- decomposing a task into sub-agent
work -- this protocol is **mandatory**. It exists because sub-agents
told to "understand the code" have repeatedly decided on their own to
start writing code, committing, and moving to the next task.

A sub-agent inherits none of your context and all of your authority.
Whatever you do not explicitly forbid, it may do.

## Every sub-agent prompt MUST contain all five

1. **Action class** -- one of the four below, stated in caps at the top.
2. **Exact scope** -- which files/modules it may read or modify. Be
   specific. Glob if you must, but prefer file lists.
3. **Deliverable** -- what it must return.
4. **Explicit prohibitions** -- what it must NOT do. Always include at
   minimum:
   - "Do NOT edit any files." (READ-ONLY / CODE-REVIEW)
   - "Do NOT commit." (IMPLEMENTATION)
   - "Do NOT proceed to the next subtask." (always)
5. **Stop condition** -- when to stop. "Stop after reporting findings."
   or "Stop after the verification suite passes."

If any is missing, the orchestrator has failed. Do not spawn.

## Action classes

| Action class       | MAY                                               | MUST NOT                                                        |
| ------------------ | ------------------------------------------------- | ----------------------------------------------------------------- |
| **READ-ONLY**      | Read, search, analyze, report findings            | Edit or write files, run state-mutating commands                  |
| **CODE-REVIEW**    | Read files, analyze diffs, report issues          | Edit or write files, commit, run tests                            |
| **IMPLEMENTATION** | Read + edit + write files within the stated scope | Touch files outside scope, commit, push, move to the next subtask |
| **COMMIT**         | Stage and commit specified changes                | Edit code, start new work                                         |

## Templates

### READ-ONLY exploration

```text
ACTION CLASS: READ-ONLY. Do NOT edit, write, or create any files.
Do NOT run any command that mutates state.

Read the following and report back:
- <exact file list, with line ranges if known>

Return: <the specific facts the orchestrator needs>

Stop after reporting. Do NOT write code. Do NOT proceed to
implementation.
```

### Scoped IMPLEMENTATION

```text
ACTION CLASS: IMPLEMENTATION. You may edit the files listed below.
Do NOT commit. Do NOT proceed to the next subtask. Do NOT touch files
outside this list.

Scope: <exact file list>

Task: <the one change, with concrete type/function names already
chosen by the orchestrator -- not "design a way to ...">

Verification: <the repo's exact commands>

Stop condition: report files modified, a summary of changes, and
verification results. Do NOT commit. Do NOT update plan documents.
Do NOT start the next subtask.
```

The orchestrator supplies the repo's real verification commands; see
`testing-mandate` for what they are per repo.

## Scope is the boundary

A sub-agent operates under `autonomy-boundaries`: it runs front to back
within its stated scope and stops the moment it would exceed it.

If a sub-agent discovers it needs to modify files outside its assigned
scope, it **must stop and report**. The orchestrator resolves the
cross-scope dependency by re-scoping or re-sequencing -- **never** by
telling the sub-agent to expand its own scope mid-task. An agent that
can widen its own boundary does not have one.

## Pre-existing bugs surfaced during a subtask

When a sub-agent finds a bug outside the current subtask's scope:

1. The sub-agent **stops and reports**. It does NOT fix the bug as part
   of the current subtask, even if the fix is one line.
2. The orchestrator records it as a **numbered cleanup entry** in the
   host task's plan document, in the same numbering space as the task.
3. The cleanup entry includes: surface point (commit + subtask), impact,
   scope of fix, suggested approach, verification criteria, and
   scheduling constraints.
4. The original subtask's completion notes **link to the cleanup entry
   by number** rather than carrying the full description.
5. Informal "known issues" sections are not used. Every surfaced bug is
   either resolved or has a numbered entry.

The point is that a bug found mid-task must survive the session. A
TODO comment or a chat message does not.

## Parallelism

Sub-agents may run concurrently only under the isolation and
decomposition rules in `parallel-work-isolation`. The short version:

- Concurrent **READ-ONLY** agents on one checkout are always safe --
  they write nothing.
- Concurrent **IMPLEMENTATION** agents on one checkout are never safe.
  They share a build directory; one agent's half-finished edit breaks
  another's test run, and the second agent then tries to "fix" damage
  that is not its own.
- Concurrent implementation requires isolated worktrees, and even then
  requires that the tasks be semantically disjoint -- not merely
  touching different files.

Load `parallel-work-isolation` before running any implementation work
in parallel.

## Orchestrator-level stop conditions

- A sub-agent's report contradicts what you expected. Do not spawn the
  next one; surface the discrepancy first.
- A sub-agent reports "I could not do this without expanding scope".
  Re-scope or re-sequence before continuing.
- The plan calls for more than about five parallel sub-agents in one
  file area. That is over-decomposition; rethink.
- Two sub-agent reports describe the same code differently. One of them
  is wrong and you do not yet know which.

## When to stop and ask

- Decomposition would require a design decision the plan did not make.
  That decision is the orchestrator's, and if the orchestrator cannot
  make it, it is the user's.
- A subtask cannot be scoped to an explicit file list. That means the
  work is not understood well enough to delegate.
