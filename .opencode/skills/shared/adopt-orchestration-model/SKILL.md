---
name: adopt-orchestration-model
description: Use when migrating one of fred's repos onto the shared orchestration model -- adopting scope-bounded autonomy, the shared orchestration/decomposition/parallel-isolation skills, and deleting per-repo duplicates of generic skills. Also use when auditing a repo's agents.md for rules that block unattended execution. Covers the opt-in declaration, the delete-vs-keep test for existing local skills, and the exact prompt to hand a migration sub-agent.
---

# Adopting the shared orchestration model

The shared skills in the nixos config repo
(`agent-orchestration-protocol`, `autonomy-boundaries`,
`plan-decomposition`, `parallel-work-isolation`, `module-cohesion`,
`state-representation`) are installed on every machine and available in
every repo. But they only take effect where a repo's `agents.md` does
not contradict them.

**This migration is opt-in and per-repo.** Most repos should not do it.
It is worth the effort only where multi-step plan-driven work actually
happens. A small repo with occasional one-off changes gains nothing and
should be left exactly as it is.

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
boundary, not a step count. `agent-orchestration-protocol` governs
sub-agent scoping, `plan-decomposition` governs turning plans into
subtasks, and `parallel-work-isolation` governs concurrent work.
```

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
format, testing mandate, markdown lint rules, module cohesion,
state representation, panic-free policy.

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
Do NOT commit.

Audit the repository at [PATH] for migration onto the shared agent
orchestration model. The shared skills are installed at
~/.config/opencode/skills/shared/ -- read agent-orchestration-protocol,
autonomy-boundaries, plan-decomposition, parallel-work-isolation,
module-cohesion, and state-representation first so you know what is
already covered generically.

Then report, with file:line citations for every finding:

1. CANDIDACY. Does this repo meet the migration criteria in
   adopt-orchestration-model? Quote the evidence. If it does not,
   say so and stop -- do not produce the rest of the report.

2. AUTONOMY BLOCKERS. Every rule in agents.md / AGENTS.md (and in any
   plan documents) that forces confirmation after each step, forbids
   multi-step execution, or is an unfalsifiable stop condition. Quote
   each one exactly.

3. GENUINE STOP TRIGGERS. Every rule that should be KEPT because it
   guards scope, invariants, or unresolved decisions. These must
   survive migration.

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
