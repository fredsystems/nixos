---
name: nixos-input-category-sync
description: Use ONLY when working in the fred/nixos flake repository AND editing flake.nix inputs, flake.lock entries, .github/workflows/ci-linux.yaml, or the `nixos-eval-impacted-hosts` skill's script. Codifies the four-place sync invariant: every flake input must be classified consistently in (1) the `# CI:` comment in flake.nix, (2) the input-to-category table in agents.md, (3) the `input_category` bash associative array in ci-linux.yaml, and (4) the `INPUT_CATEGORY` array in scripts/impacted-hosts.sh of the nixos-eval-impacted-hosts skill.
---

# NixOS: keep flake-input CI category in sync across four locations

The CI in this repo decides which hosts to rebuild based on which
flake input changed in `flake.lock`. That decision is driven by a
hand-maintained input-to-category mapping that lives in **four**
places. They must agree, or CI will either over-build (wasting
machine time) or under-build (missing required rebuilds, which is
worse).

## The four sync points

| #   | Location                                                                        | Form                                                                           |
| --- | ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| 1   | `flake.nix`                                                                     | `# CI: <category>` comment immediately above each input declaration            |
| 2   | `agents.md` (this repo)                                                         | The "Input-to-category mapping" markdown table                                 |
| 3   | `.github/workflows/ci-linux.yaml`                                               | The `input_category` bash associative array in the `Detect changed paths` step |
| 4   | `.opencode/skills/projects/nixos-eval-impacted-hosts/scripts/impacted-hosts.sh` | The `INPUT_CATEGORY` bash associative array                                    |

## Valid categories

| Category          | Meaning                                                                                  |
| ----------------- | ---------------------------------------------------------------------------------------- |
| `global`          | All Linux hosts rebuild                                                                  |
| `desktop`         | Only desktop hosts rebuild                                                               |
| `server`          | Only server hosts rebuild                                                                |
| `desktop+fredhub` | All desktops rebuild, plus `fredhub` (the one server that pulls a package from unstable) |
| `skip`            | No Linux rebuild (e.g. macOS-only inputs, dev tooling)                                   |

**Unknown / new inputs default to `global`** in all four places. That
is the safe fallback -- it may over-build but never under-builds.

## When you must update all four

- Adding a new flake input (see also: `nixos-add-flake-input` skill).
- Removing a flake input.
- Recategorizing an existing input (e.g. a server suddenly starts
  pulling a package from a previously desktop-only input).
- Renaming an input.

## Verification

1. After editing, the four locations must agree on every input. A
   one-shot check:

   ```sh
   # Inputs declared in flake.nix (root-level inputs only)
   grep -E '^\s+\w[\w-]*\.url' flake.nix | awk -F. '{print $1}' | tr -d ' '
   ```

   Cross-reference against the keys in the `input_category` arrays in
   the two scripts and the table in `agents.md`. A missing entry in
   any of those falls back to `global` -- usually safe, occasionally
   wasteful.

2. Run the impacted-hosts script against a synthetic `flake.lock`
   change for the new input to confirm the category is honored. The
   easiest way: bump the input via `nix flake update <input>`, commit,
   then run:

   ```sh
   ./.opencode/skills/projects/nixos-eval-impacted-hosts/scripts/impacted-hosts.sh HEAD~1
   ```

   The output should match the category you intended.

## When to stop and ask

- The category is genuinely ambiguous (e.g. an input is used by both
  desktops and one server in a way that doesn't cleanly map). Default
  to `global` and surface the situation to the user; do not invent a
  new category without discussion.
- An input's classification needs to change because of an unrelated
  refactor (e.g. a server stops pulling unstable). That's a separate
  PR with its own justification, not a drive-by during another change.
