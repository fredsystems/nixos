---
name: commit-discipline
description: Use whenever about to run `git commit`, `git push`, `git rebase`, `git amend`, or open a pull request in any of fred's repos. Codifies atomic-commit policy, conventional-commits format, the "never amend onto a rejected commit" rule, the "each commit must leave tests green" invariant, and the interaction with pre-commit hooks.
---

# Commit & PR discipline

The standing rules across every one of fred's repos:

## Commit shape

- **Atomic.** One logical change per commit. If you find yourself
  writing "and also..." in a commit message, split the commit.
- **Conventional Commits format**: `<type>: <subject>` (and optionally
  a scope: `<type>(<scope>): <subject>`). Common types: `feat`, `fix`,
  `refactor`, `test`, `docs`, `chore`, `ci`, `perf`, `build`.
  - In freminal, plan-subtask commits reference the subtask number:
    `refactor: 30.3 -- replace casting suppressions in freminal-common`.
- **Each commit must leave the project's primary verification green.**
  In freminal that's `cargo test --all`. In docker-acarshub it's
  `just ci`. In nixos it's `nix eval` of any impacted hosts (see the
  `nixos-eval-impacted-hosts` skill). A broken intermediate commit
  destroys `git bisect` and is not acceptable just because "the next
  commit fixes it".
- **No `--no-verify`.** Pre-commit hooks are mandatory. See the
  `precommit-fix-loop` skill for the full failure-resolution procedure.
  The only exception is when the user explicitly requests a bypass for
  one specific commit.

## When a commit gets rejected

A rejected commit is **not** a commit. There is nothing in `git log` to
fix up. So:

- **Never `git commit --amend` onto a commit that was rejected.** That
  amend is creating a _new_ commit, not fixing the rejected one. Just
  run `git commit` again (no flags) after fixing the issue. If the
  initial work was already partially staged when the hook ran, re-stage
  what you fixed and commit.
- If the rejection happened on `--amend` of a _previously accepted_
  commit and you've now lost the original message, you can recover it
  from the reflog: `git reflog show HEAD | head` shows the prior tip,
  then `git commit --amend -C <sha>` reuses that commit's message.

## Combining multiple subtasks into one commit (freminal-style)

In freminal, plan execution defaults to one commit per subtask. Merging
multiple subtasks into a single commit is **acceptable** when:

- The subtasks are individually small enough that splitting them adds
  noise.
- Multiple sub-agents worked on the same files and splitting would
  cause merge conflicts or broken intermediate states.
- The subtasks are tightly intertwined (a type change in one requires
  signature changes tracked by another).

When merging, the commit message must list every subtask number:
`refactor: 25.4 + 25.5 -- inline data.rs and remove dead Theme enum`.

This convention is freminal-specific. The other repos do not have
plan-numbered subtasks; commit-per-logical-change is the rule there.

## Branches and PRs

- **Implementation work happens on feature branches, never directly on
  `main`.**
- Branch naming follows the convention each repo establishes. In
  freminal: `task-NN/short-description` (e.g. `task-06/test-gaps`). In
  the others: any clear short kebab-case slug.
- PRs reference the underlying task / plan / issue if one exists.
- PRs are merged via the GitHub merge queue where one exists (the
  nixos repo). Do not bypass branch protection.

## Hard prohibitions

- **No force-push to `main` or any long-lived branch.** Force-push to
  your own feature branch is fine if needed to clean up history before
  review.
- **No `git rebase -i` on commits that have already been pushed and are
  visible to others.** Local cleanup only.
- **No empty commits** (`git commit --allow-empty`) unless the user
  explicitly asks for one to trigger CI.
- **No commits that contain secrets, tokens, or `.env` files.** If you
  staged one by accident, do not just remove it from the index and
  commit again -- the value is in the reflog. Rotate the secret.

## When to stop and ask

- The change you're about to commit doesn't fit cleanly into a single
  `<type>:`. Stop and propose a split.
- A pre-commit hook is rejecting in a way that would require disabling
  it. Don't disable -- surface to the user (see `precommit-fix-loop`).
- The user asked for "a commit" but you have multiple logical changes
  staged. Stop and confirm whether to split or squash.
- You're about to amend a pushed commit. Stop and confirm.
