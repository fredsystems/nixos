# Agent Guide — NixOS Flake Repository

This document explains the repository architecture, CI design, and maintenance
rules. It is written for AI coding agents and human contributors alike.

---

## Repository overview

This is a NixOS flake that manages **9 Linux hosts** (7 servers + 2 desktops)
and at least one macOS (nix-darwin) host. The infrastructure is heavily
aviation / SDR-focused — most servers run containerised ADS-B, VDL-M, and
HFDL decoders.

### Directory layout

```text
.
├── flake.nix              # Flake inputs and top-level outputs
├── flake.lock             # Pinned input revisions
├── firmware.nix           # Firmware blobs (triggers global rebuild)
├── flake/                 # Output wiring (imported by flake.nix)
│   ├── lib/               # mkSystem, mkDarwinSystem helpers
│   ├── hosts/
│   │   ├── nixos.nix      # Builds all nixosConfigurations
│   │   ├── darwin.nix     # Builds all darwinConfigurations
│   │   └── servers.nix    # Server node table (single source of truth)
│   ├── deployment/
│   │   └── colmena.nix    # Colmena remote deployment topology
│   └── dev/
│       ├── packages.nix   # Exported packages
│       ├── checks.nix     # Flake checks
│       └── shell.nix      # Dev shell (nix develop)
├── hosts/
│   └── linux/             # Per-machine NixOS configurations
│       ├── acarshub/
│       ├── daytona/       # Desktop
│       ├── fredhub/       # Server (but uses one nixpkgs-unstable package)
│       ├── fredvps/
│       ├── hfdlhub1/
│       ├── hfdlhub2/
│       ├── maranello/     # Desktop
│       ├── sdrhub/
│       └── vdlmhub/
├── modules/               # Shared NixOS modules (hardware, services, data)
├── profiles/              # System profiles (desktop, adsb-hub, …)
├── home-profiles/         # Home-manager profiles
├── features/              # Feature modules
│   └── desktop/           # Desktop-only features (isolated from servers)
├── dotfiles/              # Dotfile configurations managed by home-manager
├── overlays/              # Nixpkgs overlays
├── scripts/               # Helper scripts
└── .github/
    ├── workflows/
    │   ├── ci-linux.yaml        # Linux CI (this doc's main focus)
    │   ├── ci-darwin.yaml       # macOS CI
    │   ├── ci-lint.yaml         # Pre-commit / linting
    │   └── update-flakes.yaml   # Per-input flake update (opens 1 PR per input)
    ├── merge-queue-ci-skipper/  # Composite action: skip redundant merge-queue builds
    └── renovate.json5           # Renovate Bot config
```

### Host classification

| Host      | Type    | Notes                                     |
| --------- | ------- | ----------------------------------------- |
| Daytona   | Desktop | NixOS-unstable + home-manager (unstable)  |
| maranello | Desktop | NixOS-unstable + home-manager (unstable)  |
| fredhub   | Server  | Stable channel but pulls one unstable pkg |
| fredvps   | Server  | VPS, custom SSH port, extra user (nik)    |
| acarshub  | Server  | ADS-B decoder hub                         |
| vdlmhub   | Server  | VDL Mode 2 decoder hub                    |
| sdrhub    | Server  | SDR receiver hub                          |
| hfdlhub1  | Server  | HFDL decoder                              |
| hfdlhub2  | Server  | HFDL decoder                              |

Desktops are hardcoded in `ci-linux.yaml` as `desktop_names=("Daytona" "maranello")`.
Everything else from `nixosConfigurations` is treated as a server.

Servers default to the **stable** channel (`nixpkgs-stable`, `home-manager-stable`,
`catppuccin-stable`, `sops-nix-stable`). Per-server overrides are possible via
the node table in `flake/hosts/servers.nix`.

---

## Flake inputs and CI categories

Each flake input affects a specific subset of hosts. When a flake input is
updated (via `flake.lock` changes), CI should ideally only rebuild the hosts
that depend on that input. The current CI uses path-based filtering (not yet
input-aware — see "Future work" below), but this mapping is the authoritative
reference for that future implementation.

### Input-to-category mapping

| Input                 | CI Category             | Affects                                      |
| --------------------- | ----------------------- | -------------------------------------------- |
| `nixpkgs`             | desktop + fredhub       | Desktops + fredhub (unstable channel)        |
| `home-manager`        | desktop                 | Desktop home-manager configs                 |
| `catppuccin`          | desktop                 | Desktop theming                              |
| `niri`                | desktop                 | Niri Wayland compositor (desktop only)       |
| `fredbar`             | desktop                 | Status bar (desktop only)                    |
| `freminal`            | desktop                 | Terminal emulator (desktop only)             |
| `solaar`              | desktop                 | Logitech device manager (desktop only)       |
| `apple-fonts`         | desktop                 | Apple fonts (desktop only)                   |
| `walls-catppuccin`    | desktop                 | Wallpapers (desktop only, `flake=false`)     |
| `nixvim`              | desktop                 | Neovim config (desktop only)                 |
| `nixpkgs-stable`      | server                  | All servers (stable channel)                 |
| `home-manager-stable` | server                  | Server home-manager configs                  |
| `catppuccin-stable`   | server                  | Server theming                               |
| `sops-nix-stable`     | server                  | Server secrets management                    |
| `sops-nix`            | desktop                 | Secrets management (unstable, desktops only) |
| `nixos-needsreboot`   | global (all linux)      | Reboot detection module (all hosts)          |
| `darwin`              | skip (no linux rebuild) | macOS only — does not affect Linux CI        |
| `colmena`             | skip (no linux rebuild) | Deployment tool — no effect on builds        |
| `flake-utils`         | skip (no linux rebuild) | Utility lib — no effect on system builds     |
| `precommit-base`      | skip (no linux rebuild) | Dev tooling only — no system builds          |

**Unknown / new inputs should default to `global`** (rebuilds all Linux hosts).
This is the safe fallback — it may over-build but will never miss a required
rebuild.

### Special case: `fredhub`

`fredhub` is classified as a server and uses the stable channel by default, but
it imports one package from `nixpkgs` (unstable). Therefore, changes to
`nixpkgs` should trigger a rebuild of **desktops + fredhub** (not just
desktops).

---

## CI architecture (`ci-linux.yaml`)

### Event triggers

- `pull_request` (opened, synchronize, reopened)
- `merge_group` (merge queue)
- `workflow_dispatch` (manual — always builds everything)

### Job graph

```text
skip-if-clean
     │
     ├──▶ find-systems
     │        │
     │        ├──▶ build-servers   (matrix)
     │        └──▶ build-desktops  (matrix)
     │
     └──▶ build-linux-summary  (required status check)
```

### Merge-queue skip logic (`skip-if-clean`)

Uses `.github/merge-queue-ci-skipper/` — a composite action that detects
whether the merge-queue synthetic commit is identical to the already-tested PR
tip. If so, it outputs `skip=true` and all downstream jobs are skipped
(the summary job still runs and passes, satisfying the required check).

### Path-based and input-aware change detection (`find-systems`)

Instead of `dorny/paths-filter` (which mishandles negation patterns — see
below), we use a bash step with `git diff --name-only` and a `case` statement.
When `flake.lock` changes, we additionally parse the lock file diff to
determine which flake inputs changed and map them to CI categories.

**Why not `dorny/paths-filter`?** That action uses picomatch internally.
A negation pattern like `!features/desktop/**` becomes an independent matcher
that matches everything _except_ `features/desktop/**` — i.e., nearly every
file. Combined with other patterns via OR, the "global" filter matched on
virtually every PR, defeating the entire filtering system.

**Current `case` logic:**

```text
flake.nix | firmware.nix  → global
flake.lock  → input-aware parsing (see below)
modules/* | profiles/* | home-profiles/* | dotfiles/*  → global
features/desktop/*  → desktop_global  (checked BEFORE features/*)
features/*  → global
.github/renovate.json5  → excluded  (checked BEFORE .github/*)
.github/*  → global
hosts/linux/*  → per-machine filtering
(anything else)  → ignored
```

The `case` statement order matters: more-specific patterns (e.g.
`features/desktop/*`) are checked before their broader parents
(`features/*`). `.github/renovate.json5` is excluded before the catch-all
`.github/*` pattern.

**Input-aware `flake.lock` parsing:**

When `flake.lock` is in the changed files and `global` is not already set by
other changed paths, the workflow:

1. Retrieves the old `flake.lock` from the base commit via `git show`
2. Iterates over all root inputs in the new lock file
3. Compares `locked.rev` (or `locked.narHash` for non-git sources) between
   old and new for each input
4. Looks up each changed input in a bash associative array that maps input
   names to CI categories (`desktop`, `server`, `desktop+fredhub`, `global`,
   `skip`)
5. Sets the appropriate flags: `global`, `desktop_global`, `server_global`,
   or injects a synthetic machine path for the `fredhub` special case
6. Unknown inputs default to `global` (safe over-build)
7. Short-circuits if `global` becomes true (no point checking further)

The `desktop+fredhub` category (used only by `nixpkgs` unstable) sets
`desktop_global=true` and injects `hosts/linux/fredhub/_input_change` into
the machine files list. The downstream filtering extracts the third path
segment (`fredhub`) and includes it in the per-machine server build, while
all desktops are rebuilt.

**Filtering outcomes:**

| Scenario                                       | Servers built | Desktops built |
| ---------------------------------------------- | ------------- | -------------- |
| `global=true`                                  | All           | All            |
| `server_global=true`                           | All           | (per-machine)  |
| `desktop_global=true`                          | (per-machine) | All            |
| Only `hosts/linux/<name>/*` changed            | Only affected | Only affected  |
| Only `features/desktop/*` changed              | None          | All            |
| `flake.lock`: only `nixpkgs` changed           | Only fredhub  | All            |
| `flake.lock`: only `nixpkgs-stable` changed    | All           | None           |
| `flake.lock`: only `darwin` changed            | None          | None           |
| `flake.lock`: only `nixos-needsreboot` changed | All           | All            |
| `flake.lock`: unknown new input changed        | All           | All            |
| Only `.github/renovate.json5` changed          | None          | None           |
| `workflow_dispatch`                            | All           | All            |

### Build steps (servers and desktops)

Each matrix entry:

1. Checks out the repo
2. Installs Nix (with `access-tokens` for GitHub API auth — avoids rate limits)
3. Enables the Magic Nix Cache
4. Logs in to the **Attic binary cache** at `192.168.31.14`
5. Builds `nixosConfigurations.<host>.config.system.build.toplevel`
6. Pushes the result to Attic
7. Builds `nixosConfigurations.<host>.config.home-manager.users.fred.home.activationPackage`
8. Pushes the result to Attic
9. Fails if any `evaluation warning:` is detected in stderr

### Summary job (`build-linux-summary`)

Required status check for merge-queue / branch protection. It:

- Passes immediately if `skip-if-clean` said `skip=true`
- Passes if both build jobs succeeded or were skipped (empty matrix = no hosts in scope)
- Fails if either build job failed or was cancelled

---

## Update workflows

### `update-flakes.yaml` (custom)

- Runs weekly (Sundays at 05:00 UTC) or on `workflow_dispatch`
- Enumerates all flake inputs from `flake.lock`
- Opens **one PR per input** (branch prefix: `update-`)
- Uses `fredsystems/flake-update-action` with automerge enabled

### Renovate Bot (`.github/renovate.json5`)

- Runs weekly (Sundays at 12:00 UTC)
- **Lock file maintenance** opens a **single PR** with all `flake.lock` changes
  (this is the one that requires future input-diff parsing — see below)
- Also manages:
  - Docker container image tags (custom regex in `hosts/linux/*/configuration.nix`
    and `modules/services/mk-dozzle-agent.nix`)
  - GitHub Actions version pins
- All update types automerge via `platformAutomerge`
- Unlimited PR rate/concurrency limits

---

## Maintenance rules

### Adding a new flake input

1. Add the input to `flake.nix` under `inputs`
2. Add a `# CI: <category>` comment above it (see existing pattern in `flake.nix`)
3. **Update the input-to-category mapping table** in this file (`agents.md`)
4. **Update the `input_category` associative array** in the `Detect changed paths`
   step of `ci-linux.yaml`
5. If the input is not added to the associative array, it will default to
   `global` (safe but over-builds)

### Adding a new host

1. Create `hosts/linux/<name>/configuration.nix` (directory name lowercase)
2. If it is a server, add an entry to `flake/hosts/servers.nix`
3. If it is a desktop, add its `nixosConfigurations` attribute name to the
   `desktop_names` array in `ci-linux.yaml`
4. The CI will automatically discover it via `nix eval .#nixosConfigurations --apply builtins.attrNames`

### Adding a new desktop

Same as above, but also:

- Add the configuration name to `desktop_names` in `ci-linux.yaml`
- Changes under `features/desktop/` will automatically trigger a rebuild for
  all desktops

### Modifying CI filtering logic

The filtering logic lives in the `Detect changed paths` step of the
`find-systems` job in `ci-linux.yaml`. Key things to remember:

- `case` pattern order matters — put specific patterns before general ones
- `flake.lock` triggers the input-aware parser (not `global` directly)
- `flake.nix` and `firmware.nix` still trigger `global=true`
- To exclude a path from triggering builds, add a no-op `;;` case before the
  broader catch-all (like `.github/renovate.json5` is excluded before `.github/*`)
- The `input_category` associative array in the flake.lock parsing block must
  be kept in sync with the `# CI:` comments in `flake.nix` and the mapping
  table in this file

---

## Keeping things in sync

There are **three places** that define the input-to-CI-category mapping:

1. **`flake.nix`** — `# CI: <category>` comments above each input
2. **`agents.md`** — the input-to-category mapping table (this file)
3. **`ci-linux.yaml`** — the `input_category` bash associative array in the
   `Detect changed paths` step

When adding or recategorizing a flake input, update all three locations.
