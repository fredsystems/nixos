---
name: performance-benchmarks
description: Use when changing code in a performance-sensitive area of any of fred's projects — rendering pipelines, parsers, I/O hot paths, data-flatten loops, or anything the project's own skills flag as benchmark-mandated. Codifies the before/after capture procedure, the 15% regression threshold, the recording format, and the "add a benchmark first if none exists" rule. Project-specific skills (e.g. `freminal-bench-table`) list which benchmark file covers which area; this skill is the generic policy that uses those tables.
---

# Performance benchmarks: before/after is mandatory

If a change touches code in a benchmark-mandated area (consult the
project's own catalog skill, e.g. `freminal-bench-table`), the agent
MUST capture benchmark numbers **before and after** the change and
include them in the completion report. No exceptions.

If no appropriate benchmark exists for the code being changed, the
agent MUST create a new benchmark as part of the task **before**
proceeding with the change. Performance regressions must be
justified and documented, or the change must be revised.

## Procedure

1. Identify the relevant benchmark file(s) and benchmark name(s)
   from the project's catalog skill for the code area you're
   changing. If the project has no catalog and the area looks
   performance-sensitive, stop and ask — don't assume "there are
   no benchmarks for this".
2. **Before** making the change, capture baseline. For Criterion
   (Rust):

   ```sh
   cargo bench --bench <bench-name> -- --save-baseline before
   ```

   For other runners, use the equivalent baseline-save flag.

3. Make the change.
4. **After** the change, capture and compare:

   ```sh
   cargo bench --bench <bench-name> -- --baseline before
   ```

   The runner will print delta percentages.

5. Record results in the completion report (see format below).

## Recording format

The completion report MUST include a table like:

```text
| Benchmark | Before | After | Change |
| --- | --- | --- | --- |
| bench_handle_incoming_data | 1.23 ms | 1.19 ms | -3.3% |
```

One row per benchmark touched. Use the names the bench runner
prints, not made-up shorthand.

## Regression threshold

- Any regression **> 15%** on a relevant benchmark **must be
  justified** in the completion report (with the reason —
  correctness, maintainability, etc.) **or the change must be
  revised**.
- Regressions **≤ 15%** are acceptable if the change provides
  correctness or maintainability benefits that outweigh the
  performance cost. Still call them out explicitly.
- Wins of any size are reported as such — no need to justify a
  speedup.

## When no benchmark exists

If you're changing code in a benchmark-mandated area but no
benchmark covers the specific code path, **add a benchmark first**,
in the same PR, **before** the change. The added benchmark itself
should land in a separate commit ahead of the behavioral change so
the baseline is a clean "before" measurement.

Place new benchmarks in the crate/package that owns the code being
measured, following the existing pattern in that project.

## When to stop and ask

- The change is in a benchmark-mandated area but no obvious
  benchmark fits. Stop — describe what you'd need to benchmark and
  ask if a new benchmark is in scope.
- Numbers swing wildly between runs (>5% noise on a "no-op" rerun).
  That's bench environment noise, not a real measurement. Stop and
  rebench in a quieter shell, or surface the noise issue.
- A regression > 15% looks justified but the user might disagree.
  Surface the trade-off rather than ship it.
