---
name: nixos-eval-impacted-hosts
description: Use ONLY when working in the fred/nixos flake repository (the NixOS configuration at ~/GitHub/nixos with hosts/linux/, hosts/darwin/, modules/, profiles/, features/, home-profiles/, flake.nix, flake.lock) and a change has been made that needs verification before push. This NixOS repo has no `cargo test` equivalent -- verification is `nix eval` on the impacted hosts' system.build.toplevel.drvPath. This skill runs scripts/impacted-hosts.sh, the same script CI itself calls, so an agent or human can see exactly which hosts a change impacts and eval them locally before pushing.
---

# NixOS: eval impacted hosts before push

This repo has 10 Linux hosts + 2 macOS hosts. Running a full eval on
every host before every push is wasteful and slow. `scripts/impacted-hosts.sh`
answers "which hosts does this change actually impact" from a real
per-host derivation diff (falling through to a cheap answer first when
one is available with certainty -- see the script's own header for the
four-step algorithm). **`ci-linux.yaml` and `ci-darwin.yaml` call this
exact script** -- there is no separate mirror to keep in sync. Running
it locally shows you precisely what CI will build.

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
   ./scripts/impacted-hosts.sh --os linux
   # or, for macOS hosts:
   ./scripts/impacted-hosts.sh --os darwin
   ```

   Output is the resolved mode on stderr (`force-all`, `force-none`,
   `host-confined`, or `eval-diff`) followed by one host attribute name
   per line on stdout (e.g. `Daytona`, `fredhub`), or `no impacted
   hosts` on stderr if nothing needs a rebuild (e.g. only
   `renovate.json5` changed). There is no `GLOBAL` sentinel to
   special-case -- if every host is impacted, every host's name is
   printed, same as any other case.

   The script considers committed, staged, unstaged, and untracked
   changes by default -- it is designed to be run against a dirty tree,
   which is the normal pre-commit state. A header line on stderr reports
   exactly what it compared:

   ```text
   os: linux  |  base: origin/main (ef501737)  |  changed paths: 2
   ```

   Pass `--committed-only` to ignore the working tree and reproduce
   CI's view (`$BASE_REF...HEAD`) exactly. Pass `--json` for a
   machine-readable `{"mode": "...", "hosts": [...]}` object instead.

3. To not just _list_ the impacted hosts but actually eval them as a
   pre-push correctness gate, add `--eval`:

   ```sh
   ./scripts/impacted-hosts.sh --os linux origin/main --eval
   ```

   That runs `nix eval .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath`
   (or `.#darwinConfigurations.<host>...` for `--os darwin`) for each
   impacted host. Any eval error fails the script with a non-zero exit
   code, exactly like CI would.

4. If the eval pass succeeds, you're safe to push. CI runs the identical
   script, so it will build exactly the same set; you'll just save a
   round-trip.

## When the script disagrees with CI

It can't, in the sense that matters: CI does not run its own copy of
this logic, it runs this exact script (see the `out` step in
`ci-linux.yaml` / `find-darwin` in `ci-darwin.yaml`). If the script's
answer looks wrong, the bug is in the script, and fixing it fixes CI's
behavior at the same time -- there is nothing else to keep in sync for
the eval-diff path itself (step 4 of its algorithm; see its header).

Two things can still drift, both handled by the script's own two
allowlists rather than by remembering anything here:

- **`FORCE_ALL_FILES`** (per OS): files CI's build pipeline shells out
  to directly that aren't part of the Nix evaluation graph (workflow
  YAML, the merge-queue composite action, `scripts/attic-push.sh`,
  etc.). Missing an entry here is dangerous -- a change to an
  unregistered pipeline file could go unexercised by CI entirely -- so
  it is mechanically checked by `scripts/check-ci-pipeline-files-sync.sh`
  (pre-commit hook + flake check), not just documented. See the
  `nixos-ci-pipeline-file-sync` skill if you're adding a new script or
  local action to either workflow.
- **The inert allowlist** (`is_inert()` in the script): paths assumed
  never reachable by any Nix expression. Getting this wrong only costs
  a missed optimisation -- an unlisted inert-looking file just falls
  through to the real diff, still correct, just slower. No mechanical
  check needed; there's no correctness bug to catch.

## What the script does NOT do

- It does not run `home-manager.users.fred.home.activationPackage`
  builds. CI does this as a later step of each matrix job. For a really
  thorough pre-push check, add a follow-up eval:

  ```sh
  for h in $(./scripts/impacted-hosts.sh --os linux); do
    nix eval ".#nixosConfigurations.${h}.config.home-manager.users.fred.home.activationPackage.drvPath" >/dev/null
  done
  ```

- It does not push to Attic. CI does that on success.

## When to stop and ask

- The script reports every host impacted (`force-all` or a full-fleet
  `eval-diff` result) for a change that intuitively should only hit one
  or two hosts. Either that's genuinely correct (you edited something
  foundational, e.g. `flake.nix`, or a `FORCE_ALL_FILES` entry), or
  there's a script bug. Run with `bash -x` to see which branch fired.
- The script reports `no impacted hosts` for a change you are certain
  touches a host. Check the stderr header first: if `changed paths` is
  `0` on a tree you believe is dirty, you are probably in the wrong
  directory or diffing the wrong base ref.
- A host eval fails with a warning rather than an error. CI fails on
  any `evaluation warning:` in stderr, so treat warnings as fatal too.
