---
name: nixos-add-flake-input
description: Use ONLY when working in the fred/nixos flake repository AND the task is to add (or remove) a flake input in flake.nix. Walks the four-location sync requirement, the `# CI:` comment convention, and the post-add verification that confirms CI will rebuild the right host set when the new input changes.
---

# NixOS: adding a new flake input

Adding an input to `flake.nix` is a small mechanical change that has
to land in four files at once to keep CI honest. The mapping rule and
the why are in the `nixos-input-category-sync` skill; this one is the
step-by-step.

## Procedure

1. **Pick the category** the input belongs to. See the table in
   `nixos-input-category-sync`. If genuinely unclear, default to
   `global` -- safe over-build.

2. **Add the input to `flake.nix`** with a `# CI:` comment on the
   line immediately above it:

   ```nix
   # CI: desktop
   my-new-input = {
     url = "github:someone/something";
     inputs.nixpkgs.follows = "nixpkgs";
   };
   ```

   The `# CI:` comment is mandatory. It documents the choice for
   future readers and is the human source of truth that the other
   three places mirror.

3. **Wire the input through** wherever it's consumed -- typically
   the `flake/lib/mkSystem.nix` or `flake/lib/mkDarwinSystem.nix`
   helpers, or directly in a feature module. This is the part that
   actually does anything useful.

4. **Update `agents.md`** -- add a row to the input-to-category
   mapping table with the same category you put in the `# CI:`
   comment, plus a short "Affects" description.

5. **Update `.github/workflows/ci-linux.yaml`** -- add the input to
   the `input_category` associative array in the `Detect changed
paths` step:

   ```bash
   input_category[my-new-input]="desktop"
   ```

6. **Update the impacted-hosts script** at
   `.opencode/skills/projects/nixos-eval-impacted-hosts/scripts/impacted-hosts.sh`
   -- add the same entry to its `INPUT_CATEGORY` array.

7. **Lock the new input**:

   ```sh
   nix flake lock --update-input my-new-input
   ```

   (Or it'll be locked automatically the first time `nix eval` runs
   against the flake.)

8. **Verify**:
   - The eval still works:

     ```sh
     nix eval .#nixosConfigurations --apply 'cfgs: builtins.attrNames cfgs' --json
     ```

   - The impacted-hosts script reports the right host set for a
     synthetic update of the new input. Bump it, commit, then:

     ```sh
     ./.opencode/skills/projects/nixos-eval-impacted-hosts/scripts/impacted-hosts.sh HEAD~1
     ```

     For a `desktop`-category input, this should print the two
     desktop hostnames. For `global`, it prints `GLOBAL`. For
     `skip`, it prints nothing. For `desktop+fredhub`, it prints
     both desktops plus `fredhub`.

9. **Commit**. Convention: `chore(flake): add <input-name> input`.

## Removing an input

Same procedure in reverse. Remove from all four places. CI will not
silently break -- the input simply won't appear in `flake.lock`, so
the parser won't try to categorize it. But leaving stale entries in
the bash array and the markdown table is sloppy and will mislead
future readers.

## Recategorizing an input

Update the category in all four places in the same commit. Mention
the rationale in the commit message -- why did it change?

## When to stop and ask

- The input has a non-obvious classification (used by both classes
  but only sometimes). Default to `global`, surface the ambiguity.
- The input is large / slow to fetch (e.g. a big `flake=false`
  source tree). Mention impact on CI time before adding it.
- The input replaces an existing one. That's two coupled changes;
  do them in separate commits if possible, and update all four
  locations for both.
