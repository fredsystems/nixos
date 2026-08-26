---
name: nixos-add-flake-input
description: Use ONLY when working in the fred/nixos flake repository AND the task is to add (or remove) a flake input in flake.nix. Walks the wiring and verification steps for a new input, now that CI impact is decided by a real derivation diff rather than a hand-maintained category per input.
---

# NixOS: adding a new flake input

Adding an input to `flake.nix` used to require updating a hand-maintained
category in four separate files so CI would rebuild the right hosts when
it changed. That's gone: `scripts/impacted-hosts.sh` (called directly by
`ci-linux.yaml` and `ci-darwin.yaml`) decides impact from a real per-host
derivation diff, so a bumped input either changes a host's closure or it
doesn't -- nothing to categorize, nothing to keep in sync, no default to
fall back on if you guess wrong. Adding an input is now just wiring plus
verification.

## Procedure

1. **Add the input to `flake.nix`**:

   ```nix
   my-new-input = {
     url = "github:someone/something";
     inputs.nixpkgs.follows = "nixpkgs";
   };
   ```

2. **Wire the input through** wherever it's consumed -- typically the
   `flake/lib/mk-system.nix` / `flake/lib/mk-darwin-system.nix` helpers,
   or directly in a feature module. This is the part that actually does
   anything useful, and it's also what determines impact now: whichever
   hosts end up with this input reachable from their module set are the
   ones a future bump of it will rebuild, automatically, with no
   separate bookkeeping step.

3. **Lock the new input**:

   ```sh
   nix flake lock --update-input my-new-input
   ```

   (Or it'll be locked automatically the first time `nix eval` runs
   against the flake.)

4. **Verify**:
   - The eval still works:

     ```sh
     nix eval .#nixosConfigurations --apply 'cfgs: builtins.attrNames cfgs' --json
     ```

   - `scripts/impacted-hosts.sh` reports the right host set for a
     synthetic update of the new input. Bump it, commit, then:

     ```sh
     ./scripts/impacted-hosts.sh --os linux HEAD~1
     # and, if the input also reaches a darwin host:
     ./scripts/impacted-hosts.sh --os darwin HEAD~1
     ```

     This runs the real eval-diff (the input bump isn't in either
     `FORCE_ALL_FILES` or the inert allowlist, so it can't take a
     shortcut) and should print exactly the hosts you expected the
     input to reach -- no more, no less. If it prints hosts you didn't
     expect, either your wiring reaches further than you thought, or
     there's a genuine bug; don't dismiss the discrepancy.

5. **Commit**. Convention: `chore(flake): add <input-name> input`.

## Removing an input

Remove it from `flake.nix` and unwire it from wherever it was consumed.
There's no category table or bash array to clean up anymore -- the only
remaining trace to check for is a stray `follows` reference from another
input.

## When to stop and ask

- The input is large / slow to fetch (e.g. a big `flake=false` source
  tree). Mention impact on CI time before adding it.
- The input replaces an existing one. That's two coupled changes; do
  them in separate commits if possible, and verify impact for both.
- The verification step (4) reports a host set that doesn't match your
  intent for the wiring. That's a real signal to investigate, not
  something to paper over by re-running with a different base ref.
