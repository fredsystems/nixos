# Agent Guide -- NixOS Flake Repository

This document is the always-on orientation for AI coding agents and human
contributors working in this NixOS flake. **Operational procedures are no
longer inlined here** -- they live as opencode skills under
`.opencode/skills/` and are loaded on demand. This document gives you the
map; the skills give you the moves.

---

## Repository overview

This is a NixOS flake managing **10 Linux hosts** (8 servers + 2 desktops)
and at least one macOS (nix-darwin) host. The infrastructure is heavily
aviation / SDR-focused -- most servers run containerised ADS-B, VDL-M,
and HFDL decoders.

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
│       ├── nvrhub/
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
├── opencode.jsonc         # opencode project config for this repo
├── .opencode/             # Skills directory: this repo holds the
│   │                      # cross-repo shared + generic-language skills
│   │                      # used by every one of fred's projects. The
│   │                      # `ai.opencode` home-manager module bakes this
│   │                      # tree into the derivation and installs it at
│   │                      # `~/.config/opencode/skills/`, so Colmena
│   │                      # targets do NOT need this checkout at runtime.
│   │                      # Project-specific skills live in each
│   │                      # respective project repo's `.opencode/skills/`.
│   └── skills/
│       ├── shared/        # Cross-repo policies (precommit, commits,
│       │                  # testing, no-summary-documents, flaky tests,
│       │                  # performance benchmarks, flake dev-shell,
│       │                  # markdown-lint-discipline) plus the
│       │                  # orchestration model: agent-orchestration-
│       │                  # protocol, autonomy-boundaries, plan-
│       │                  # decomposition, plan-sequencing-discipline,
│       │                  # parallel-work-isolation, module-cohesion,
│       │                  # state-representation,
│       │                  # adopt-orchestration-model. The
│       │                  # orchestration set is OPT-IN per repo --
│       │                  # a repo declares it in its own agents.md.
│       ├── languages/     # Per-language rules (rust, typescript)
│       └── projects/      # nixos-specific procedures only
└── .github/
    ├── workflows/
    │   ├── ci-linux.yaml        # Linux CI
    │   ├── ci-darwin.yaml       # macOS CI
    │   ├── lint.yaml            # Pre-commit / linting
    │   ├── fleet-manifest.yaml  # Publishes per-host expected closure paths
    │   └── update-flakes.yaml   # Per-input flake update (1 PR per input)
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
| nvrhub    | Server  | NVR host, stateVersion 26.05              |

Desktops are hardcoded in `ci-linux.yaml` as
`desktop_names=("Daytona" "maranello")`. Everything else from
`nixosConfigurations` is treated as a server.

Servers default to the **stable** channel (`nixpkgs-stable`,
`home-manager-stable`, `catppuccin-stable`, `sops-nix-stable`).
Per-server overrides are possible via the node table in
`flake/hosts/servers.nix`.

`fredhub` is a stable-channel server that imports one package from
unstable `nixpkgs`. CI treats changes to the `nixpkgs` input as
"desktops + fredhub".

---

## Execution model

This repo uses the shared orchestration model. `autonomy-boundaries`
governs when to continue versus stop: the assigned scope is the
boundary, not a step count, and irreversible operations still need
explicit approval. `agent-orchestration-protocol` governs sub-agent
scoping, `plan-decomposition` governs turning plans into subtasks,
`plan-sequencing-discipline` governs the numbered plan set (ordering,
cross-plan dependencies, status at merge), and
`parallel-work-isolation` governs concurrent work.

Note what that declaration does. opencode discovers the shared skills
globally and loads them by description match, so their presence is not
opt-in. What this section opts into is **authority**: `agents.md` is
always-on core context and therefore outranks an on-demand skill, so
without this declaration a repo's own `agents.md` would win any
conflict. Repos that have not declared the model are followed as
written. See `adopt-orchestration-model`.

## Skills you will need in this repo

These are loaded on demand by opencode when their description matches
the task. The full bodies live under `.opencode/skills/`.

| Skill                       | When it fires                                                                                      |
| --------------------------- | -------------------------------------------------------------------------------------------------- |
| `nixos-eval-impacted-hosts` | Before pushing any change. Computes impacted hosts from the diff and runs evals.                   |
| `nixos-input-category-sync` | When editing flake inputs / `flake.lock` / `ci-linux.yaml` / the impacted-hosts script.            |
| `nixos-add-host`            | When adding a new host (server or desktop).                                                        |
| `nixos-add-flake-input`     | When adding (or removing) a flake input.                                                           |
| `agent-orchestration-protocol` | Before spawning sub-agents. Action classes, scope, prohibitions, stop conditions.               |
| `autonomy-boundaries`       | Executing a multi-step plan. Scope is the boundary, not a step count.                              |
| `plan-decomposition`        | Turning a plan or epic into implementable subtasks.                                                |
| `plan-sequencing-discipline` | Maintaining a numbered plan set: ordering, cross-plan deps, status at merge, index drift.         |
| `parallel-work-isolation`   | Running more than one implementation agent at once. Worktrees, foundation-first, merge-back.       |
| `adopt-orchestration-model` | Migrating another repo onto the shared orchestration model.                                        |
| `module-cohesion`           | Adding a type to a file that names a different concept.                                            |
| `state-representation`      | Adding a `bool` field or parameter, or crossing a boundary with one.                               |
| `precommit-fix-loop`        | When a commit is rejected by pre-commit hooks.                                                     |
| `commit-discipline`         | Before any commit / PR.                                                                            |
| `testing-mandate`           | Before declaring any task done.                                                                    |
| `no-summary-documents`      | Before creating any new markdown file.                                                             |
| `markdown-lint-discipline`  | Before writing or editing any `.md` file. MD031, MD040, table widths, no emojis in tables.         |
| `nix-best-practices`        | When editing any `.nix` file. Codifies the active strict lint stack (nixfmt + statix + deadnix).   |
| `nixos-track-upstream-fix`  | When adding/reverting a temporary workaround for an unfixed upstream bug (overlay, disabled feat). |

If the skill doesn't fire automatically and you think it should, that
means the skill description needs a stronger trigger -- fix the skill,
don't paste its contents into this file.

---

## CI in one paragraph

`ci-linux.yaml` has a `find-systems` job that classifies changed paths
(via a bash `case` statement) and parses `flake.lock` diffs (input-aware)
to decide which hosts to rebuild. `dorny/paths-filter` was rejected
because negation patterns under picomatch match nearly every file. The
matrix builds toplevel + home-manager activation for each impacted host
and pushes to the Attic binary cache at `192.168.31.14`. Any
`evaluation warning:` in stderr fails the build. `build-linux-summary`
is the required status check.

The full input-to-category mapping lives in the
`nixos-input-category-sync` skill -- both the reference table and the
list of the four machine-readable copies that must agree with it
(`flake.nix` comments, `ci-linux.yaml`, `ci-darwin.yaml`, and the
impacted-hosts script). It is deliberately **not** duplicated here.
When changing it, load that skill; the
`input-category-sync` pre-commit hook and flake check enforce
agreement mechanically.

Both `ci-linux.yaml` and `ci-darwin.yaml` also carry a `dev-shell`
build-and-push job (one per OS, on the self-hosted runners). The host
matrix only caches `toplevel` + home-manager activation, so the dev
shell (`nix develop`) and the per-system `packages.*` outputs (colmena
CLI, lint tooling, wallpapers) would otherwise be rebuilt locally on
every machine. The job builds `.#devShells.<system>.default` and every
`.#packages.<system>.*` and pushes them to Attic. It is **gated by its
own `find-devshell` detection job**, which is independent of the host
filter because the dev shell has a different input set: it rebuilds only
when `flake/dev/*.nix`, a CI workflow file, or one of the inputs that
actually feed the shell changes -- `nixpkgs`, `precommit-base`,
`colmena`, or the `walls-*` wallpaper inputs. Note that `precommit-base`
and `colmena` are `skip` for the host filter but **do** trigger the dev
shell. Keep that `devshell_inputs` list in sync (in both workflows) when
the dev shell's dependencies change.

Three inputs deliberately do **not** follow our `nixpkgs` so their
prebuilt outputs can be substituted from the projects' own caches:
`colmena` (colmena.cachix.org), `catppuccin` (catppuccin.cachix.org),
and `niri` (niri.cachix.org / niri-epireyn.cachix.org). Those caches are
wired both into `flake.nix`'s `nixConfig` (for ad-hoc builds) and into
`modules/base/system.nix` (so every host's `/etc/nix/nix.conf` uses them
during normal `nixos-rebuild` / `nix develop`). Following our `nixpkgs`
would change their derivation hashes and force local source builds.

## Update workflows

- **`update-flakes.yaml`** runs weekly, opens one PR per input via
  `fredsystems/flake-update-action` with automerge.
- **Renovate Bot** runs weekly; lock file maintenance opens a single PR
  with all `flake.lock` changes; also manages Docker image tags and
  GitHub Actions pins; everything automerges via `platformAutomerge`.

---

## Maintenance rules (one-liners; full procedures in skills)

- **Adding a new host** -> `nixos-add-host` skill.
- **Adding / removing / recategorizing a flake input** ->
  `nixos-add-flake-input` skill, which references
  `nixos-input-category-sync`.
- **Verifying a change before push** -> `nixos-eval-impacted-hosts`
  skill (includes a bundled script that mirrors the CI's filter
  exactly).
- **Modifying CI filtering logic in `ci-linux.yaml`** -> remember the
  `case` order rule (specific patterns before broad ones) and the
  four-place sync invariant; load `nixos-input-category-sync`.
- **Adding / reverting a temporary workaround for an unfixed upstream
  bug** (overlay, `permittedInsecurePackages`, disabled feature, polkit
  hack) -> register it in `.github/tracked-upstream-fixes.json` so the
  `track-upstream-fixes.yaml` workflow flags it for removal once the fix
  lands; load `nixos-track-upstream-fix`.
- **Never put the flake's git revision into a host's closure.** No
  `self.rev` in `system.activationScripts`, no `environment.etc` entry
  holding it, no `system.configurationRevision`. Anything reachable from
  `system.build.toplevel` that embeds the commit SHA makes every commit
  change every host's store path, which destroys the fleet's only exact
  "does this host need a deploy?" signal. Deploy state is derived by
  comparing `/run/current-system` against the manifest published by
  `fleet-manifest.yaml`; the revision is recovered by reverse lookup.
  See the note in `flake/lib/mk-system.nix` and
  `scripts/gen-fleet-manifest.sh`.

---

## What this file deliberately does NOT contain

The following used to live here. They were moved to skills to keep this
file as a stable orientation document and to avoid paying the token cost
on every turn:

- The full input-to-category mapping table -> `nixos-input-category-sync`.
- The step-by-step procedures for adding hosts and inputs -> their
  respective skills above.
- The detailed CI job graph and filtering outcome table -> implementation
  detail; trust the workflow itself and the impacted-hosts script.
- The "three places to keep in sync" warning -> elevated to four places
  (the impacted-hosts script is a fourth) in
  `nixos-input-category-sync`.

If you're tempted to add a long procedure back to this file, write it as
a skill instead.
