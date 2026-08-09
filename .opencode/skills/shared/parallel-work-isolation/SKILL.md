---
name: parallel-work-isolation
description: Use whenever planning or executing work that runs more than one implementation agent at the same time in any of fred's repos -- deciding whether tasks can be parallelised, setting up git worktrees, choosing a branch topology, or merging parallel workstreams back. Codifies the file-conflict vs logic-conflict distinction, the foundation-first pattern for shared types, the one-active-editor-per-region rule, per-worktree build directories, and the integration-branch merge model. Load this before spawning concurrent IMPLEMENTATION sub-agents.
---

# Parallel work isolation

Running several implementation agents at once is only safe when both
halves are handled:

1. **Mechanical isolation** -- they must not corrupt each other's
   files or build artifacts.
2. **Semantic isolation** -- they must not independently change the
   same behaviour.

Most parallel-agent failures come from solving (1) and assuming it
covered (2). It does not.

## The distinction that matters most

> Worktrees stop file conflicts. They do not stop logic conflicts.
> Two agents, two folders, zero merge conflicts, and both quietly
> change how the same function behaves. Git sees no overlap. The tests
> pass in each worktree alone. They break when both land.

Git detects **textual** conflict only. It has no concept of two agents
independently changing what a function _does_. A clean merge whose
combined behaviour is wrong is the characteristic failure of parallel
agent work, and no isolation technology prevents it. Only decomposition
does.

So the first question is never "how do I isolate these agents" but
**"are these tasks actually independent?"**

## Deciding whether tasks can run in parallel

Tasks are parallel-safe only when all hold:

- **Disjoint files.** No two tasks edit the same file.
- **Disjoint behaviour.** No two tasks change the same observable
  behaviour, invariant, or data flow, even through different files.
- **No shared-type edits.** Neither adds a field, variant, or
  signature change to a type the other consumes. This is the most
  commonly missed one -- see foundation-first below.
- **Independent verification.** Each task's tests pass on its own
  branch _and_ would still pass with the other task's changes applied.

If any fails, the tasks are sequential, or need a foundation step
first. "They touch different files" is necessary, not sufficient.

## Foundation-first for shared types

When several tasks each need to add to a shared type -- a common enum,
a config struct, a bottom-of-the-dependency-graph crate -- do **not**
let them race that edit in parallel branches. Instead:

1. Land **one** foundation change on the integration branch that adds
   every shared shell the parallel tasks need: the new variants, the
   new fields, the new config keys, the new signatures.
2. Fork the feature branches from the foundation-carrying integration
   branch.
3. Each feature branch then fills in behaviour behind an interface
   that already exists and that nobody else is editing.

This converts the worst class of conflict (structural edits to a shared
type, which merge badly and break every downstream crate) into no
conflict at all. It costs one extra sequenced step and saves a merge
disaster.

## One active editor per shared region

Where tasks genuinely must touch the same file or region, branches
prevent corruption but do not remove the merge-conflict and
review-serialization tax. Keep **at most one actively-editing agent per
shared-file region at a time**, and rebase the other branches after
each merge.

"Parallel" here means parallel _branches and workstreams_, not several
agents editing the same file at the same instant.

## Mechanical isolation: git worktrees

A worktree gives each agent its own working directory, `HEAD`, and
index against one shared object store.

**Verified isolated per worktree:** working files, `HEAD`, index,
`ORIG_HEAD`, per-worktree refs.

**Verified shared across all worktrees -- these bite:**

| Shared            | Consequence                                                           |
| ----------------- | ----------------------------------------------------------------------- |
| `.git/config`     | A config change in one worktree is immediately visible in all others   |
| `.git/hooks`      | One hook set for every worktree                                        |
| `refs/stash`      | `git stash` is effectively one global variable across all worktrees    |
| Object store      | Safe for concurrent commits, but see `gc` below                        |

Rules that follow:

- **Never `git stash` in an agent worktree.** A stash pushed in one
  tree is visible in every other, and a `stash pop` in the wrong tree
  applies someone else's changes. Commit to a scratch branch instead.
- **Each agent gets its own branch.** Git refuses to check out the same
  branch in two worktrees; this is a feature, not an obstacle.
- **Do not run `git gc --prune=now` while agents are working.** Git's
  own documentation states concurrent `gc` carries a real (if low)
  corruption risk. Let `gc.auto` be, and run manual gc when idle.

### Setup

```sh
git worktree add ../<repo>-<task> -b <task-branch> <integration-branch>
```

Each worktree gets its own build directory automatically, because
build tools default to a path relative to the tree root.

### Teardown

```sh
git worktree remove ../<repo>-<task>
git worktree prune
```

Remove worktrees when the task merges. Stale worktrees hold branch
locks and confuse the next run.

## Build isolation

**Give every worktree its own build directory.** Do not point several
worktrees at one shared build output.

For Rust specifically: do **not** share `CARGO_TARGET_DIR` across
worktrees. Cargo's lock is per-target-directory and is not aware that
two trees hold different source. Across divergent trees you get either
full serialization (losing the parallelism you set this up for) or
corrupted artifacts. Cargo's own maintainers scope the "safe to share"
claim to a single source tree building different packages -- not to
different worktrees on different branches.

The cost is a full dependency build per worktree. Recover it with a
shared compiler cache (`sccache` via `RUSTC_WRAPPER`), which is the
documented way to share compilation across checkouts without sharing
the build directory. Note that a shared cache helps most with
dependency compilation and least with incremental rebuilds of the crate
under active edit.

Expect occasional brief contention on the global package-cache lock
(`~/.cargo/.package-cache`) even with separate build directories. That
is a real lock working correctly, not a hang -- but it does mean
concurrent dependency-fetching agents will sometimes wait on each
other.

## Containers are usually the wrong tool here

Containers isolate processes and OS state. The parallel-agent problem
is semantic disagreement between agents, which containerization does
not touch. For a single-language project with no external services they
add real cost -- language-server wiring, display plumbing for GUI
tests, copy-on-write penalties on build directories unless you mount
them out -- for isolation that worktrees already provide.

Reach for containers only when you need genuine service isolation (a
per-agent database) or OS-level sandboxing.

**If a repo is Nix-flake-managed, do not introduce a container whose
toolchain is defined separately from the flake.** That reintroduces the
toolchain-drift problem the flake exists to eliminate. Build the image
from the flake so the lock file stays the single source of truth.

## Branch topology and merging back

For a version or epic executed as several parallel tasks:

```text
main
 └── <version>-integration          the eventual single PR
      ├── task-a/<slug>
      ├── task-b/<slug>
      └── task-c/<slug>
```

- Feature branches fork from the **integration branch**, not `main`.
- The foundation change lands on the integration branch first.
- Each task merges back into the integration branch when green.
- After each merge, the other live branches **rebase** on the
  integration branch to pick up shared changes before continuing.
- When all tasks are in, **one PR**: integration branch to `main`.

Merging back is orchestrator work. Do it **sequentially, one branch at
a time**, running the full verification suite after each merge -- not
just the merged branch's tests. The whole point is to catch the
semantic collision that each branch's own tests cannot see. Never
octopus-merge parallel agent branches: that pattern is for trivial
non-conflicting merges, not for reconciling independently written code.

If verification fails only after two branches are combined, that is a
logic conflict. Stop and surface it; do not patch over it in the
integration branch without understanding which task's assumption was
wrong.

## When to stop and ask

- Task decomposition cannot produce semantically disjoint tasks. Say so
  and run sequentially; forced parallelism produces the clean-merge,
  broken-behaviour failure.
- Two parallel branches both need to change the same shared type and a
  foundation step cannot cover it.
- Combined verification fails after a merge that each branch passed
  alone.
- The number of parallel worktrees is growing to keep agents busy
  rather than because the work is genuinely independent.
