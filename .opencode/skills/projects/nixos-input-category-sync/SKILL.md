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

| #   | Location                                                                        | Form                                                                            |
| --- | ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| 1   | `flake.nix`                                                                     | `# CI: <category>` comment immediately above each input declaration             |
| 2   | `.github/workflows/ci-linux.yaml`                                               | The `input_category` bash associative array in the `Detect changed paths` step  |
| 3   | `.github/workflows/ci-darwin.yaml`                                              | Its own `input_category` array, using the **Darwin** categories (see below)     |
| 4   | `.opencode/skills/projects/nixos-eval-impacted-hosts/scripts/impacted-hosts.sh` | The `INPUT_CATEGORY` bash associative array                                     |

The reference table below (in this skill) is the human-readable
statement of intent. The four locations above are the machine-readable
copies that must agree with it.

**Do not put the mapping table in `agents.md`.** It used to be cited
there, and `agents.md` now explicitly delegates it here -- for a while
both documents pointed at each other and the concrete table existed in
neither, which is exactly how `nixpkgs-kernel` went unnoticed in two of
the arrays. The table lives here; `agents.md` links to it.

Run `scripts/check-input-category-sync.py` (bundled with this skill) to
verify all four mechanically. It runs in pre-commit and CI, so drift is
caught rather than remembered.

## Reference table (statement of intent)

Linux categories, as of the `nixpkgs-kernel` sync fix:

| Input                     | Linux category    | Why                                                    |
| ------------------------- | ----------------- | ------------------------------------------------------ |
| `nixpkgs`                 | `desktop+fredhub` | Unstable; desktops plus the one server pulling from it |
| `nixpkgs-stable`          | `server`          | Stable channel; all servers                            |
| `nixpkgs-kernel`          | `server`          | Server kernel pin only; desktops no-op the pin         |
| `home-manager`            | `desktop`         | Unstable home-manager                                  |
| `home-manager-stable`     | `server`          | Stable home-manager                                    |
| `catppuccin`              | `desktop`         | Unstable theming                                       |
| `catppuccin-stable`       | `server`          | Stable theming                                         |
| `sops-nix`                | `desktop`         | Unstable secrets                                       |
| `sops-nix-stable`         | `server`          | Stable secrets                                         |
| `nix-yazi-plugins`        | `desktop`         | Unstable yazi plugins                                  |
| `nix-yazi-plugins-stable` | `server`          | Stable yazi plugins                                    |
| `niri`                    | `desktop`         | Desktop compositor                                     |
| `nix-flatpak`             | `desktop`         | Desktop-only flatpak module                            |
| `lan-mouse`               | `desktop`         | KVM home-manager module; maranello only                |
| `freminal`                | `desktop`         | Terminal emulator, desktops only                       |
| `frext`                   | `desktop`         | Desktop tooling                                        |
| `github-ci-exporter`      | `server`          | Prometheus exporter; runs on sdrhub only               |
| `walls-catppuccin`        | `desktop`         | Wallpapers                                             |
| `walls-zhichaoh`          | `desktop`         | Wallpapers                                             |
| `walls-cozypixels`        | `desktop`         | Wallpapers                                             |
| `nixvim`                  | `global`          | Editor config on every Linux host                      |
| `nixos-needsreboot`       | `global`          | Reboot helper on every Linux host                      |
| `darwin`                  | `skip`            | macOS only                                             |
| `colmena`                 | `skip`            | Deployment tool; no effect on host closures            |
| `flake-utils`             | `skip`            | Utility lib                                            |
| `precommit-base`          | `skip`            | Dev tooling only                                       |

Darwin uses its own two-value vocabulary in `ci-darwin.yaml`: `darwin`
(rebuild the Mac) or `skip`. An input is `darwin` only if it actually
reaches `mkDarwinSystem` -- note `nix-yazi-plugins` (unstable) does,
while `nix-yazi-plugins-stable`, `nix-flatpak`, and `nixpkgs-kernel` do
not.

Note that a `skip` for Linux is not automatically a `skip` for Darwin,
and vice versa: `darwin` is `skip` in `ci-linux.yaml` and `darwin` in
`ci-darwin.yaml`. Reason about each workflow separately.

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

1. Run the checker. It cross-references the reference table in this
   skill against all four machine-readable locations, using
   `flake.lock`'s root inputs as the source of truth for which inputs
   must be present:

   ```sh
   ./.opencode/skills/projects/nixos-input-category-sync/scripts/check-input-category-sync.py
   ```

   It reports missing entries, categories that disagree between
   locations, values outside the valid vocabulary, and stale entries
   for inputs that no longer exist. This also runs as the
   `input-category-sync` pre-commit hook and as the
   `.#checks.<system>.input-category-sync` flake check, so drift is
   caught even when nobody remembers to run it by hand.

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
