---
name: nixos-eval-impacted-hosts
description: Use ONLY when working in the fred/nixos flake repository (the NixOS configuration at ~/GitHub/nixos with hosts/linux/, modules/, profiles/, features/, home-profiles/, flake.nix, flake.lock) and a change has been made that needs verification before push. This NixOS repo has no `cargo test` equivalent -- verification is `nix eval` on the impacted hosts' system.build.toplevel.drvPath. This skill computes which hosts are impacted from the git diff (mirroring the CI's path-based filter and flake.lock input-aware parser) and runs the evals locally so push-time CI failures are caught beforehand.
---

# NixOS: eval impacted hosts before push

This repo has 9 Linux hosts + macOS. Running a full eval on every host
before every push is wasteful and slow. CI already filters down to just
the impacted hosts using a `case` statement in
`.github/workflows/ci-linux.yaml` plus an input-aware parser for
`flake.lock` diffs. **This skill bundles a script that mirrors that
exact logic locally**, so an agent or human can run the same filter
before pushing and catch eval errors that would otherwise blow up CI.

## `git add` any new file before evaluating

**Nix flakes evaluate the git index, not the working directory.** A
file that exists on disk but is untracked is invisible to `nix eval`.
Modifications to already-tracked files _are_ picked up without staging;
it is only new files that vanish.

The failure mode is nasty because it is green: add
`hosts/linux/newhost/configuration.nix`, run the eval, watch it pass,
and conclude the new host is fine. It was never evaluated at all.

So, before any eval:

```sh
git add -A          # or `git add` the specific new paths
```

You do **not** need to commit. Staging is enough for the flake to see
the file. This matters because the whole point of the gate is to verify
_before_ committing.

The script enforces this: it warns whenever untracked files are present,
and `--eval` hard-fails rather than producing a PASS that proves
nothing.

## Procedure

1. Make your changes. `git add -A` if you created any new files (see
   above) -- committing is not required.
2. From the repo root, run:

   ```sh
   ./.opencode/skills/projects/nixos-eval-impacted-hosts/scripts/impacted-hosts.sh
   ```

   Output is one host attribute name per line (e.g. `Daytona`,
   `fredhub`), or the single token `GLOBAL` if every host needs a
   rebuild. `no impacted hosts` on stderr means nothing needs a rebuild
   (e.g. only the `darwin` input changed, or only `renovate.json5`).

   The script considers committed, staged, unstaged, and untracked
   changes -- it is designed to be run against a dirty tree, which is
   the normal pre-commit state. A header line on stderr reports exactly
   what it compared:

   ```text
   base: origin/main (ef501737)  |  commits: 0  |  modified: 2  |  untracked: 0
   ```

   Pass `--committed-only` to ignore the working tree and reproduce
   CI's view (`$BASE_REF...HEAD`) exactly.

3. To not just _list_ the impacted hosts but actually eval them as a
   pre-push correctness gate, add `--eval`:

   ```sh
   ./.opencode/skills/projects/nixos-eval-impacted-hosts/scripts/impacted-hosts.sh origin/main --eval
   ```

   That runs `nix eval .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath`
   for each impacted host. Any eval error fails the script with a
   non-zero exit code, exactly like CI would.

4. If the eval pass succeeds, you're safe to push. CI will perform the
   same filtering and likely rebuild the same set; you'll just save a
   round-trip.

## When the script disagrees with CI

If you observe the script saying "X hosts" but CI rebuilding a different
set, **the script is wrong, not CI**. The CI workflow is the source of
truth. Cases where drift happens:

- A new flake input was added to `flake.nix` but the `INPUT_CATEGORY`
  array in this script was not updated. All four locations must agree
  (`flake.nix` comments, `ci-linux.yaml`, `ci-darwin.yaml`, and this
  script's array); the reference table lives in the
  `nixos-input-category-sync` skill. Default to `global` for any
  unknown input — safe over-build. Run that skill's
  `check-input-category-sync.py` to confirm; it also runs as a
  pre-commit hook and a flake check.
- A new desktop host was added but `desktop_names=(...)` in CI was not
  updated. This script reads `desktop_names` from CI at runtime so it
  auto-recovers, but CI itself will be broken until the array is fixed.
- The `case` patterns in `ci-linux.yaml` were edited. Sync the changes
  into the script's `case` block.

If you find yourself updating this script to track a CI change, also
update the related skill: `nixos-input-category-sync` (which holds the
reference table and tracks the flake input -> CI category mapping
across its four sync points).

## What the script does NOT do

- It does not run `home-manager.users.fred.home.activationPackage`
  builds. CI does this as step 7-8 of each matrix job. For a really
  thorough pre-push check, add a follow-up eval:

  ```sh
  for h in $(./.opencode/skills/projects/nixos-eval-impacted-hosts/scripts/impacted-hosts.sh); do
    [[ "$h" == "GLOBAL" ]] && break
    nix eval ".#nixosConfigurations.${h}.config.home-manager.users.fred.home.activationPackage.drvPath" >/dev/null
  done
  ```

- It does not check Darwin hosts. The `darwin` flake input is
  classified `skip` for Linux CI, and Darwin builds happen in a
  separate workflow.

- It does not push to Attic. CI does that on success.

## When to stop and ask

- The script reports `GLOBAL` for a change that intuitively should only
  hit one or two hosts. Either the `case` logic genuinely flagged a
  broad path (e.g. you edited `modules/`), or there's a script bug. Run
  with `bash -x` to see which branch fired.
- The script reports `no impacted hosts` for a change you are certain
  touches a host. Check the stderr header first: if `modified` and
  `untracked` are both `0` on a tree you believe is dirty, you are
  probably in the wrong directory or diffing the wrong base ref.
- A host eval fails with a warning rather than an error. CI fails on
  any `evaluation warning:` in stderr (see ci-linux.yaml step 9), so
  treat warnings as fatal too.
