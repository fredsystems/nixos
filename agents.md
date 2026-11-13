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
│       │                  # markdown-lint-discipline,
│       │                  # shebang-env-discipline) plus the
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

Desktops are declared directly in `flake/hosts/nixos.nix`; every server
comes from the node table in `flake/hosts/servers.nix`. CI does not
distinguish them: it builds whichever hosts' closures changed, in one
matrix.

Servers default to the **stable** channel (`nixpkgs-stable`,
`home-manager-stable`, `catppuccin-stable`, `sops-nix-stable`).
Per-server overrides are possible via the node table in
`flake/hosts/servers.nix`.

`fredhub` is a stable-channel server that imports one package from
unstable `nixpkgs`, so an unstable bump can rebuild it alongside the
desktops.

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
| `nixos-eval-impacted-hosts` | Before pushing any change. Runs scripts/impacted-hosts.sh (the same script CI calls) and evals.    |
| `nixos-ci-pipeline-file-sync` | Adding/removing a script or local action that ci-linux.yaml / ci-darwin.yaml shells out to.      |
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
| `shebang-env-discipline`    | Writing/editing any script with a `#!` line. Must be `#!/usr/bin/env <exec>`, never a fixed path.  |
| `nixos-track-upstream-fix`  | When adding/reverting a temporary workaround for an unfixed upstream bug (overlay, disabled feat). |

If the skill doesn't fire automatically and you think it should, that
means the skill description needs a stronger trigger -- fix the skill,
don't paste its contents into this file.

---

## CI in one paragraph

`ci-linux.yaml`'s `find-systems` job and `ci-darwin.yaml`'s
`find-darwin` job both call the same script, `scripts/impacted-hosts.sh`,
to decide which hosts to rebuild. That script answers from a real
per-host derivation diff (`system.build.toplevel.outPath` at base vs.
HEAD, evaluated -- never built -- so it costs about a minute, not a
build) rather than guessing from file paths, with two allowlist
fast-paths ahead of the real diff for the common cases where the answer
is knowable without one. See the script's own header for the full
four-step algorithm and the `nixos-eval-impacted-hosts` skill for running
it locally. The matrix builds each impacted host's toplevel (which
includes its home-manager activation) and pushes it to the Attic binary cache at
`192.168.31.14`. Any `evaluation warning:` in stderr fails the build.
`build-linux-summary` is the required status check.

One of the script's two allowlists (`FORCE_ALL_FILES`, per OS) covers
files CI's pipeline shells out to directly but that aren't part of the
Nix evaluation graph -- workflow YAML, the merge-queue composite action,
helper scripts like `attic-push.sh`. Missing an entry there is a real
gap (a change to an unregistered pipeline file could go unbuilt
entirely), so it's mechanically checked by
`scripts/check-ci-pipeline-files-sync.sh` (pre-commit hook + flake
check) rather than just documented; see the `nixos-ci-pipeline-file-sync`
skill when adding a script or local action to either workflow.

Both `ci-linux.yaml` and `ci-darwin.yaml` also carry a `dev-shell`
build-and-push job (one per OS, on the self-hosted runners). The host
matrix only caches host closures (`toplevel`), so the dev
shell (`nix develop`) and the per-system `packages.*` outputs (colmena
CLI, lint tooling, wallpapers) would otherwise be rebuilt locally on
every machine. The job builds and pushes exactly the
`.#devShells.<system>.*` / `.#packages.<system>.*` outputs whose outPath
changed, as reported by the same script with `--target dev` (run from
`find-systems` / `find-darwin`). There is no list of files or inputs
that "feed the dev shell" to keep in sync: an `overlays/` change that
moves `.#sbomnix`, or a `precommit-base` bump that moves only the dev
shell, is caught by the diff itself.

Three inputs deliberately do **not** follow our `nixpkgs` so their
prebuilt outputs can be substituted from the projects' own caches:
`colmena` (colmena.cachix.org), `catppuccin` (catppuccin.cachix.org),
and `niri` (niri.cachix.org / niri-epireyn.cachix.org). Those caches are
listed once, in `flake.nix`'s `nixConfig` (which must be a literal);
`modules/base/system.nix` reads that list into every host's
`/etc/nix/nix.conf`, adding the LAN Attic cache and cache.nixos.org. The
self-hosted CI runners are fleet hosts, so they use that same
`nix.conf`; no workflow lists caches. Following our `nixpkgs` would
change their derivation hashes and force local source builds.

`opencode` does not follow our `nixpkgs` either, for a different reason:
its `nixpkgs` supplies the Bun that installs `node_modules` (whose
fixed-output hash depends on it) and is compiled into the binary. It is
pinned to a release tag that only Renovate bumps (policy `renovate` in
`.github/flake-input-policy.json`, so `update-flakes.yaml` skips it).
`renovate-relock.yaml` advances `opencode/nixpkgs` when upstream's
release lock has a Bun outside `package.json`'s `packageManager` range,
and records the `node_modules` hash per release + toolchain. Do not run
a bare `nix flake update` / `nix flake update opencode` and commit the
result: it resets `opencode/nixpkgs` to upstream's lock, and the overlay
will refuse to evaluate until `scripts/opencode-node-modules-hash.sh
relock` is run.

## Update workflows

- **`update-flakes.yaml`** runs weekly, opens one PR per input via
  `fredsystems/flake-update-action` with automerge.
- **Renovate Bot** runs weekly; lock file maintenance opens a single PR
  with all `flake.lock` changes; also manages Docker image tags and
  GitHub Actions pins; everything automerges via `platformAutomerge`.

---

## Maintenance rules (one-liners; full procedures in skills)

- **Adding a new host** -> `nixos-add-host` skill.
- **Adding / removing a flake input** -> `nixos-add-flake-input` skill.
  No category to pick anymore; impact is decided by a real derivation
  diff.
- **Verifying a change before push** -> `nixos-eval-impacted-hosts`
  skill, which runs `scripts/impacted-hosts.sh` -- the exact script CI
  itself calls, not a mirror of it.
- **Adding a script or local action that `ci-linux.yaml` /
  `ci-darwin.yaml` shells out to** -> it must be registered in
  `scripts/impacted-hosts.sh`'s `FORCE_ALL_FILES` array or a change to
  it could go unbuilt; load `nixos-ci-pipeline-file-sync`, which is
  checked mechanically, not just documented.
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
- **`inputs` is the only extra module argument.** Beyond the standard
  ones (`config`, `lib`, `pkgs`, ...), the builders pass
  `specialArgs = { inherit inputs; }` on NixOS, Darwin and Colmena, and
  `extraSpecialArgs = { inherit inputs; }` on Home Manager, and nothing
  else as a module argument. Fleet data is a `shared.*` option
  (`modules/base/fleet-identity*.nix`), a flake input's module is wired
  by the builder (not imported by a module), and an OS- or role-specific
  half is listed by its caller. Only host-specific code may take `inputs`
  as a module argument. Nothing an export reaches may require it (an
  export can still close over the flake's inputs lexically, as
  `nixosModules.dependencies` does in `flake/exports.nix`). The
  `exports-standalone` check (run in `lint.yaml`) evaluates every export
  without it, but only in the configurations it builds: a read behind an
  option those leave disabled is not caught, so keep the rule rather than
  relying on the check alone. Exports are documented in `MODULES.md`; see
  `agent-docs/plans/PLAN_04_MODULE_INTERFACES.md` for why.

---

## What this file deliberately does NOT contain

The following used to live here. They were moved to skills to keep this
file as a stable orientation document and to avoid paying the token cost
on every turn:

- The step-by-step procedures for adding hosts and inputs -> their
  respective skills above.
- The detailed CI job graph and filtering outcome table -> implementation
  detail; trust the workflow itself and the impacted-hosts script.

If you're tempted to add a long procedure back to this file, write it as
a skill instead.
