---
name: testing-mandate
description: Use before declaring any task complete in fred's repos, before opening a PR, when adding a new function/module/service, or when fixing a bug. Codifies the mandatory-testing policy that applies across freminal (cargo test + benches), docker-acarshub (vitest + playwright), and the NixOS repo (nix eval of impacted hosts). "It compiles and old tests pass" is never sufficient -- new code requires new tests, bug fixes require regression tests, and a task is not done until verification is green.
---

# Testing is mandatory

## The rule

Every new feature, bug fix, or refactor MUST include tests that cover
the new or changed behavior. "It compiles and existing tests pass" is
explicitly **insufficient**. New code requires new tests; bug fixes
require regression tests; and a task is not "done" until the project's
verification suite is fully green.

This applies in all of fred's repos. The shape differs per project:

| Repo              | New code requires                                                                                                                                                                                                                  | Bug fix requires                                                                                                      | Final verification before "done"                                                                                      |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `freminal`        | Unit tests in the same crate (in `tests/` or `#[cfg(test)]` module). Performance-sensitive code in render/PTY/buffer also requires before/after benchmark numbers.                                                                 | A regression test that FAILS without the fix and PASSES with it.                                                      | `cargo test --all`, `cargo clippy --all-targets --all-features -- -D warnings`, `cargo machete`. Or `cargo xtask ci`. |
| `docker-acarshub` | Vitest tests under the appropriate `__tests__/` directory. New components also need accessibility coverage.                                                                                                                        | Regression test in vitest (or Playwright if the bug is UX-level).                                                     | `just ci`.                                                                                                            |
| `nixos`           | Not unit-testable in the programmatic sense. The equivalent: a successful `nix eval` of `system.build.toplevel` (and `home.activationPackage` when home-manager changes) for every impacted host. See `nixos-eval-impacted-hosts`. | A reproducer in the form of the bad eval before, the green eval after. Capture the exact error in the commit message. | `nix eval` of impacted hosts (the `nixos-eval-impacted-hosts` skill bundles a script).                                |

## Coverage expectations

These are floors, not ceilings. Pushing above them is encouraged.

- **freminal**: target 100% across crates. Public APIs without tests are
  treated as incomplete.
- **docker-acarshub**:
  - Utilities: 90%+
  - Stores: 80%+
  - Components: 70%+
  - Backend services: 80%+
  - Backend formatters/enrichment: 90%+
- **nixos**: not a coverage metric; the "eval of every impacted host
  succeeds" gate is the equivalent.

## Test quality

Tests are first-class code. They must be:

- **Hermetic.** No external network, no shared filesystem state across
  tests, no global mutable state.
- **Order-independent.** A test must pass whether it runs alone, first,
  last, or in parallel with the rest of the suite.
- **Focused on observable behavior**, not implementation details. A
  test that breaks on a pure refactor is testing the wrong thing.
- **Written for humans first.** A failing test should explain what
  invariant it was checking, not just "expected X got Y".

Duplication in tests is acceptable if it improves clarity. Do not
extract test helpers so aggressively that a reader can't see what's
being asserted without three jumps.

## Flake handling (docker-acarshub specifically, generalizes)

A flaky test is a broken test. The full no-punting rules live in the
`flaky-tests-are-bugs` skill, but the headline applies to every
repo: do not paper over a sporadic failure with a retry, longer
timeout, or `it.skip`. Root-cause it.

## What "the task is done" means

A task is done ONLY when ALL of the following are true:

1. Every new public surface area has tests (or, in nixos, has been
   evaluated successfully on every impacted host).
2. If this was a bug fix, a regression test exists that demonstrably
   fails without the fix.
3. The project's full verification suite (per the table above) passes
   cleanly with zero warnings.
4. The relevant plan document (if any) has been updated to reflect
   completion -- without spawning a new summary doc (see
   `no-summary-documents`).
5. The commit history is clean (atomic, conventional commits, each
   commit green -- see `commit-discipline`).

If any of these is false, the task is in progress, not done. Report it
that way.

## When to stop and ask

- The new code is genuinely untestable as designed (e.g. a hardware
  side-effect with no abstraction boundary). Stop -- the fix is to add
  the abstraction, not to skip the test. Surface this to the user.
- The existing test infrastructure is missing for the area you're
  working in. The implementing agent must create the infrastructure
  (test module, helpers, fixtures) as part of the task, but stop and
  confirm scope with the user before doing a large infrastructure
  bring-up.
- A test is failing for reasons unrelated to your change. Do NOT skip
  it. Do NOT push around it. Stop, surface it, and fix it (it counts
  as a flake -- see the flake policy).
