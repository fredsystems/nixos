---
name: no-summary-documents
description: Use whenever about to create a new markdown file, write documentation, or finalize a multi-step task in any of fred's repos (nixos, freminal, docker-acarshub, and downstream). Codifies the strict no-summary-documents policy -- no PHASE_X_SUMMARY.md, no IMPLEMENTATION_PROGRESS.md, no REFACTOR_NOTES.md, no "what I did" markdown. Documentation only exists if it is durable reference material.
---

# No summary documents — ever

Across every one of fred's repos, the rule is the same: **do not create
markdown files that summarize work that was done.** This includes (but
is not limited to):

- `PHASE_X_SUMMARY.md`, `PHASE_1_COMPLETE.md`, `MILESTONE_*.md`
- `IMPLEMENTATION_PROGRESS.md`, `PROGRESS.md`, `STATUS.md`
- `REFACTOR_NOTES.md`, `MIGRATION_NOTES.md`, `CHANGES.md`
  (when it duplicates `CHANGELOG.md` or git history)
- `SESSION_NOTES.md`, `WORKLOG.md`
- "Recap" / "wrap-up" / "what was done in task N" documents
- Per-PR or per-commit `*_SUMMARY.md` files

These files are summaries of _the work_, not of _the system_. They go
stale immediately, they duplicate `git log`, and they pollute repo
search results forever.

## What documentation IS allowed

Documentation must serve a **durable** purpose. Acceptable:

| Type                  | Examples                                                           | Why durable                                    |
| --------------------- | ------------------------------------------------------------------ | ---------------------------------------------- |
| Reference             | `ARCHITECTURE.md`, `agent-docs/DECODER_CONNECTIONS.md`             | Describes how the system works today           |
| Standards / patterns  | `DESIGN_LANGUAGE.md`, `TESTING.md`, `AGENTS.md`                    | Defines rules the codebase must follow         |
| Coverage / inventory  | `Documents/ESCAPE_SEQUENCE_COVERAGE.md`                            | Authoritative table updated with each change   |
| Active plan documents | `Documents/PLAN_XX_*.md`, `Documents/MASTER_PLAN.md` (in freminal) | Living working documents for in-progress tasks |
| Onboarding            | `README.md`, `DEV-QUICK-START.md`, `CONTRIBUTING.md`               | First-read material for newcomers              |
| Changelogs            | `CHANGELOG.md` (one per repo)                                      | Single canonical history file, not per-task    |

If the document you're tempted to write doesn't fit one of these, the
answer is no.

## What goes where instead of a summary doc

| Instinct                                                     | Right destination                                                                                            |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| "I want to capture what I did in task 12"                    | Commit message (one per logical change). That IS the durable record.                                         |
| "I want to track what subtasks are complete"                 | Tick boxes in the existing `Documents/PLAN_XX_*.md`. Do NOT spawn a new file.                                |
| "I want to summarize a refactor for posterity"               | Update the relevant reference doc (`ARCHITECTURE.md`, etc.) to reflect the new state. Discard the narrative. |
| "I want to record decisions made during the task"            | If the decision is durable, ADR-style entry in an existing decisions doc. If situational, commit message.    |
| "I want to leave handoff notes for the next session / agent" | They live in the existing plan doc, or in the chat with the user. NOT a new markdown file.                   |
| "I discovered a bug while doing X"                           | File it as a numbered cleanup entry in the host task's plan section (freminal convention), or open an issue. |

## Hard prohibitions

- Do not create a markdown file just because you "completed" something.
- Do not create a markdown file to "track progress" outside of an
  already-existing plan document.
- Do not create a markdown file because the user asked for "a summary"
  -- they meant a chat response, not a file. If genuinely uncertain,
  ask.
- Do not create per-PR review notes as markdown files in the repo. PR
  description and review comments are the venue.

## When to stop and ask

- The user explicitly asks for "documentation of X" and X is genuinely
  new system-level knowledge (e.g. a newly added subsystem). Propose
  the file name and location FIRST, get approval, then write -- do not
  preemptively create.
- A plan document is missing for an in-progress multi-step task and the
  task is large enough to need one. Stop and confirm with the user
  before spawning `Documents/PLAN_XX_*.md`.
- You're tempted to write "notes for the next agent". Don't. The
  durable replacements above cover every legitimate case; the others
  belong in the conversation, not in the repo.
