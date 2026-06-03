---
name: flaky-tests-are-bugs
description: Use whenever a test fails sporadically, when CI fails for "the flaky one", when a test depends on parallel scheduling or timing, when a retry is being considered, or when `it.skip` / longer timeouts / fake-async patches are being proposed. Codifies the no-punting policy: a flaky test is a broken test, root-cause it before continuing other work. Applies to every one of fred's repos regardless of language.
---

# Flaky tests are broken tests — no punting

A flaky test is a broken test. Period. CI failures caused by flakes
we already knew about are unacceptable — every red CI run that turns
out to be "oh, that one's just flaky" erodes trust in the suite and
trains everyone to ignore real failures.

This policy applies across every one of fred's repos (freminal,
docker-acarshub, nixos, anything new). If a flake surfaces during
any work (a CI retry, a `cargo test` / `npm test` loop, parallel-suite
stress, manual repro — anything), it becomes a **hard blocker** under
the following rules.

## The rules

1. **Finish the current sub-task.** Do not abandon a half-done
   refactor or partially-staged change. Finish what's in flight and
   leave it in a clean committable state.
2. **The very next unit of work is the flake fix.** No new
   features, no new refactors, no jumping to the next plan item
   until the flake is either:
   - fixed, or
   - proven to be environmental noise outside the test code (and
     even then: documented and tracked).
3. **Root-cause it.** Symptomatic patches are NOT acceptable:
   - Test retries (`it.retry(N)`, `--retries`, `extend({ retries })`,
     `#[retry]` macros, etc.)
   - Longer timeouts to mask a race
   - `it.skip` / `#[ignore]` with a TODO
   - `flaky: true` tags that disable the test in CI
   - "Run it three times and take majority"

   Identify the actual race / shared-state / boundary issue and fix
   the _cause_.

4. **Add a deterministic regression test** that reproduces the race
   reliably without depending on parallel scheduling. The flaky
   test itself does NOT count as the regression test — flakes by
   definition pass sometimes, so they can't gate the fix. The
   regression test must fail with 100% reliability without the fix.
5. **Stress-test the fix.** Minimum **10 consecutive full-suite
   runs clean** before declaring victory. More if the original
   repro rate was lower than 1-in-5 (e.g. a 1-in-50 flake needs at
   least 50 clean runs to be statistically meaningful).
6. **Never push a known flake to `main` or any long-lived branch.**
   If a flake surfaces mid-way through long-lived work, it gets
   its own commit ahead of further feature/refactor work on the
   same branch.

## Multiple flakes during one sub-task

If you find more than one flake during a single sub-task:

1. Finish the current sub-task.
2. Queue all the flakes.
3. Drain the queue in order of **reproduction frequency** (most
   frequent first) before resuming planned work.

## What "environmental noise" actually means

Acceptable as "not a code bug":

- A CI runner with intermittent disk pressure that no test code can
  defend against (rare; usually solvable in CI config).
- A network call to a third-party that's genuinely outside the
  project's control. The fix is to mock it, not to retry.
- A timezone / locale assumption in the CI runner that's reasonable
  to fix in CI config.

Not acceptable as "environmental":

- "It depends on which test ran before it." → shared state in the
  suite. Code bug.
- "It depends on which order the runner schedules workers." → order
  dependence. Code bug.
- "It depends on whether the dev machine is fast." → race
  condition. Code bug.
- "It depends on the moon phase." → you didn't root-cause it.

## When to stop and ask

- The flake is real, root-caused, and the fix is _architectural_
  (e.g. the whole test infrastructure assumes shared state).
  Surface the scope before doing a multi-day refactor.
- The flake is in a third-party tool (e.g. a Playwright bug, a
  tokio scheduler quirk). The workaround might be a version pin or
  a transient retry _with a comment linking to the upstream issue_
  and a follow-up plan to remove it once upstream ships a fix.
  Confirm that case with the user; don't decide unilaterally that
  "this one's the upstream's fault".
