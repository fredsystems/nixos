---
name: nixos-ci-pipeline-file-sync
description: Use ONLY when working in the fred/nixos flake repository AND adding, removing, or renaming a script/local composite-action that .github/workflows/ci-linux.yaml or ci-darwin.yaml shells out to directly (e.g. a new `./scripts/foo.sh` step, or a new `uses: ./.github/some-action`). Codifies the FORCE_ALL_FILES sync invariant in scripts/impacted-hosts.sh: any such file is invisible to a derivation diff, so it must be registered or a change to it can silently go unbuilt.
---

# NixOS: keep CI pipeline files registered in scripts/impacted-hosts.sh

`scripts/impacted-hosts.sh` decides whether a change forces a rebuild of
every host, based on a real derivation diff between base and HEAD --
except for one category of file it can never see a change to: the CI
pipeline's own machinery. Workflow YAML and the scripts/actions it
shells out to are not part of the Nix evaluation graph, so if they
aren't explicitly registered, a change to them could pass through the
classifier reporting "nothing impacted" and never get exercised by CI
at all. That is the dangerous failure mode this skill exists to prevent.

Contrast this with the script's *other* allowlist (`is_inert()`, for
paths assumed never reachable by any Nix expression): getting that one
wrong only costs a missed optimisation, because an unlisted inert-ish
file just falls through to the real diff and still gets the right
answer, just slower. `FORCE_ALL_FILES` has no such safety net -- getting
it wrong means a real gap in CI coverage -- which is why it gets a
mechanical check instead of a documented habit.

## The one sync point

`scripts/impacted-hosts.sh` has two `FORCE_ALL_FILES` arrays, one per
OS, each inside the `case "$OS" in linux) ... darwin) ... esac` block.
Every local script/action reference in the corresponding workflow file
must appear, verbatim, in that array.

`scripts/check-ci-pipeline-files-sync.sh` verifies this mechanically: it
parses `ci-linux.yaml` and `ci-darwin.yaml` for every `./scripts/*.sh`
invocation and local `uses: ./...` composite-action reference, and
fails if any of them is missing from the matching array. It runs as the
`ci-pipeline-files-sync` pre-commit hook and the
`.#checks.<system>.ci-pipeline-files-sync` flake check, so drift is
caught rather than remembered.

## When you must update the array

- Adding a `run: ./scripts/<something>.sh` (or any invocation form the
  checker's grep patterns match) step to `ci-linux.yaml` or
  `ci-darwin.yaml`.
- Adding a new local composite action (`uses: ./.github/<something>`)
  to either workflow.
- Renaming or removing a script/action that was previously registered
  (the checker only fails on missing entries, not stale ones -- it
  prints stale entries as a non-fatal note, but clean them up anyway).

A script that's shared by both workflows (e.g.
`scripts/attic-push.sh`) needs an entry in *both* arrays, even though
it's the same file -- the two arrays describe two independent
pipelines that happen to both use it.

`scripts/impacted-hosts.sh` itself is registered in both of its own
arrays, for the same reason: it's invoked directly by both workflows
and isn't part of the Nix evaluation graph, so a bug introduced in a
change to only that file would otherwise report "nothing impacted" and
never get exercised. Don't remove that entry.

## Verification

```sh
bash scripts/check-ci-pipeline-files-sync.sh
```

Or via the flake check, which is how CI actually runs it:

```sh
nix build .#checks.x86_64-linux.ci-pipeline-files-sync
```

Both exit non-zero and print exactly which reference is missing from
which array.

## When to stop and ask

- A script is invoked by one workflow but not the other, and you're
  unsure whether it should be registered for both, one, or neither.
  Reason about it from first principles (does a change to this file
  matter if only Linux/only Darwin hosts are being considered?), and
  surface the ambiguity rather than guessing.
- The checker's grep patterns don't match a new invocation style you've
  added (e.g. calling a script via an interpreter other than bash, or a
  `uses:` form the patterns don't cover). Extend the checker's
  extraction patterns rather than manually registering the file and
  leaving the mechanical check blind to that shape going forward.
