---
name: adopt-orchestration-model
description: Use when migrating one of fred's repos onto the shared orchestration model -- adopting scope-bounded autonomy, the shared orchestration/decomposition/parallel-isolation skills, and deleting per-repo duplicates of generic skills. Also use when auditing a repo's agents.md for rules that block unattended execution. Covers the opt-in declaration, the delete-vs-keep test for existing local skills, and the exact prompt to hand a migration sub-agent.
---

# Adopting the shared orchestration model

The shared skills (`agent-orchestration-protocol`,
`autonomy-boundaries`, `plan-decomposition`,
`parallel-work-isolation`, `module-cohesion`, `state-representation`)
are installed at `~/.config/opencode/skills/` on every machine.

## What is and is not opt-in

Be precise about the mechanism, because it is easy to overstate:

- **Discovery is global and cannot be opted out of.** opencode scans
  the global skills directory and loads any skill whose description
  matches the task. There is no per-repo switch that hides them.
- **What is opt-in is authority.** `agents.md` is always-on core
  context; skills are loaded on demand. So when a repo's `agents.md`
  says "stop and confirm after every step" and `autonomy-boundaries`
  says "run the whole scope", **the repo's `agents.md` wins**. The
  shared skill is loaded but overridden.

The declaration below is what resolves that conflict. Adding it is the
act of adoption; without it, a repo that still carries a
confirm-every-step rule keeps that behaviour even though the skill is
present.

**The agent-side rule, stated once:** if a repo's `agents.md` declares
the shared orchestration model, `autonomy-boundaries` governs
continue-versus-stop. If it does not, follow that repo's `agents.md` as
written and do not apply scope-bounded autonomy on your own initiative.

**Migration is per-repo and most repos should not do it.** It is worth
the effort only where multi-step plan-driven work actually happens. A
small repo with occasional one-off changes gains nothing and should be
left exactly as it is.

## Is this repo a candidate?

Migrate only if **most** of these hold:

- Work is driven by plan or roadmap documents with numbered tasks.
- Sessions routinely span many steps.
- Sub-agents are used for decomposition.
- The repo has local skills that duplicate generic policy.
- `agents.md` contains a rule forcing confirmation after every step.

If a repo is just "make this change" work, stop here. Leave it alone.

## What migration changes

### 1. Declare the opt-in

Add to the repo's `agents.md`, near the top:

```markdown
## Execution model

This repo uses the shared orchestration model. `autonomy-boundaries`
governs when to continue versus stop: the assigned scope is the
boundary, not a step count, and irreversible operations still need
explicit approval. `agent-orchestration-protocol` governs sub-agent
scoping, `plan-decomposition` governs turning plans into subtasks,
`plan-sequencing-discipline` governs the numbered plan set (ordering,
cross-plan dependencies, status at merge), and
`parallel-work-isolation` governs concurrent work.
```

Name every shared skill the repo is granting authority to. A skill left
out of this list is still discovered and still loaded, but it does not
outrank the repo's own `agents.md`, so a conflict silently resolves the
old way. Drop any line that does not apply -- a repo with no numbered
plan set does not need the `plan-sequencing-discipline` clause.

Absent that declaration, the repo keeps whatever its `agents.md`
already says.

### 2. Remove the rules that block autonomy

The specific patterns to find and replace -- these are what make
unattended execution impossible:

| Pattern to remove                                     | Why                                                        |
| ----------------------------------------------------- | ------------------------------------------------------------ |
| "Stop and post a summary -- wait for confirmation"    | Makes the user a manual scheduler for already-approved work |
| "Do NOT execute multiple steps in one session"        | Directly forbids finishing an approved plan                 |
| "You feel unsure but think you can guess"             | Unfalsifiable; an agent can always claim it                 |
| Per-step confirmation gates inside plan documents     | Same problem, moved into the plan                           |

Replace with a pointer to `autonomy-boundaries`. **Keep** every
genuine stop trigger: ambiguous requirements, weakened invariants,
scope expansion, unresolved design decisions, `TENTATIVE` markers.

The distinction: remove rules that stop **correct in-scope work**.
Keep rules that stop **work outside scope or on a broken assumption**.

### 3. Apply the delete-vs-keep test to local skills

For each local skill, ask: **would this rule be wrong in another
repo?**

- **No, it is generic** -- delete it and rely on the shared skill.
  Check the shared skill actually covers it first; if it is missing a
  case, add the case to the shared skill rather than keeping the local
  copy.
- **Yes, it is repo-specific** -- keep it. Trim any generic preamble
  that now duplicates a shared skill, and reference the shared skill
  instead.

Keep repo-specific: architecture invariants, which benchmark covers
what, wiring checklists for this repo's config system, per-file
gotchas, domain rules, plan-status conventions tied to this repo's
documents.

Delete as generic: orchestration protocol, subtask contracts, commit
format, testing mandate, markdown lint rules, module cohesion, state
representation.

One qualification on language policy. The panic-free rule
(`unwrap`/`expect` forbidden outside tests) lives in
`rust-best-practices`, which is a **language** skill, not a shared one.
Delete a local copy only if the repo is Rust and the rule genuinely
matches; a non-Rust repo's equivalent rule (unchecked assertions,
swallowed exceptions) has no shared skill covering it yet, so keep it
locally or raise the gap first. Do not delete a language-specific rule
on the assumption that a shared skill covers it -- check.

A local skill that is 80% generic and 20% specific gets **rewritten
down to the 20%**, with a line pointing at the shared skill for the
rest. Do not leave the duplicated 80% in place "for convenience" -- two
copies of a rule drift, and the local copy silently wins.

### 4. Record the execution model in plan documents

If the repo's plans describe parallelism ad hoc, replace that prose
with a reference to `parallel-work-isolation` plus the repo-specific
facts: the branch topology, which tasks are genuinely disjoint, and
which shared types need a foundation-first step.

Reasoning about parallelism that lives only in one plan document is
lost the moment that version ships. It belongs in the skill.

## Migration prompt

Hand this to a sub-agent, one repo at a time. Fill in the bracket.

```text
ACTION CLASS: READ-ONLY. Do NOT edit, write, or create any files.
Do NOT commit. Do NOT run any command that mutates state (no git
checkout/stash/add/commit, no package installs, no formatters). Do NOT
proceed to the next subtask or begin the migration itself.

Audit the repository at [PATH] for migration onto the shared agent
orchestration model. The shared skills are installed at
~/.config/opencode/skills/shared/ -- read agent-orchestration-protocol,
autonomy-boundaries, plan-decomposition, parallel-work-isolation,
module-cohesion, state-representation, and adopt-orchestration-model
itself first, so you know both what is already covered generically and
what the migration criteria are.

Then report, with file:line citations for every finding:

1. CANDIDACY. A repo is a candidate only if MOST of these hold:
   work is driven by plan/roadmap documents with numbered tasks;
   sessions routinely span many steps; sub-agents are used for
   decomposition; local skills duplicate generic policy; agents.md
   forces confirmation after every step. Quote the evidence for each.
   If the repo is not a candidate, say so and stop -- do not produce
   the rest of the report.

2. AUTONOMY BLOCKERS. Every rule in agents.md / AGENTS.md (and in any
   plan documents) that forces confirmation after each step, forbids
   multi-step execution, or is an unfalsifiable stop condition. Quote
   each one exactly.

3. GENUINE STOP TRIGGERS. Every rule that should be KEPT because it
   guards scope, invariants, unresolved decisions, or irreversible
   operations. These must survive migration. The distinction: a rule
   that stops correct in-scope work is a blocker (section 2); a rule
   that stops work outside scope or on a broken assumption is a
   keeper.

4. LOCAL SKILL TRIAGE. For each skill in .opencode/skills/, classify
   as DELETE (fully covered by a shared skill -- name which),
   TRIM (mostly generic; state which parts are the repo-specific
   remainder), or KEEP (genuinely repo-specific). Give a one-line
   reason each.

5. SHARED SKILL GAPS. Anything in a local skill that is generic but
   NOT yet covered by a shared skill. These need adding upstream
   before the local copy can be deleted -- this is the most important
   section, because deleting an uncovered rule loses it.

6. PARALLELISM. Any reasoning about parallel execution, branch
   topology, or worktrees currently living in plan documents rather
   than in a skill. Quote it.

Do NOT make any changes. Report only. Stop after reporting.
```

Then review the report yourself before authorising an IMPLEMENTATION
pass. Section 5 in particular is where knowledge gets lost: if the
audit found a generic rule the shared skills do not cover, add it
upstream **first**, then delete the local copy.

## Order of operations

1. Run the audit prompt. Read the report.
2. Fix any shared-skill gaps found in section 5, in the nixos repo.
   Deploy so the updated skills are installed.
3. Only then, in the target repo: update `agents.md`, delete/trim local
   skills, update plan documents.
4. Verify the repo's own suite still passes and that a plan-driven
   session behaves as expected.

Migrating the target repo before closing the upstream gaps loses rules.

## When to stop and ask

- The audit finds a rule that looks generic but the user may have added
  deliberately for that repo. Ask; do not delete a rule whose history
  you cannot see.
- Two repos disagree about a rule that should be shared. That
  disagreement needs resolving before either is migrated -- surface
  both versions.
- A repo's plan documents encode a parallelism model that contradicts
  `parallel-work-isolation`. The repo may know something the shared
  skill does not; surface it rather than overwriting.
