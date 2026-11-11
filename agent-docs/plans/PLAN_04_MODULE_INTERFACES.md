# Plan 04: Module interfaces

- **Status:** in progress
- **Branches:** one `plan04/4.N-*` branch and PR per subtask, stacked
  on the previous one and merged in order.

## Goal

Every `nixosModules.*` and `homeModules.*` export evaluates on its own,
in a bare `nixpkgs.lib.nixosSystem` (or Home Manager configuration) with
no `specialArgs`, and a flake check keeps it that way. Internally, the
only `specialArg` left is `inputs`, used only by host-specific code.

## Background

A bare-`nixosSystem` evaluation of each export (2026-11-10) found 9 of
15 working. The other 6 failed in two ways:

- **Builder arguments.** `adsb-hub`, `desktop-common`, `default` and
  `github-runners` hit infinite recursion or missing arguments: they
  need `specialArgs` that only `flake/lib/mk-system.nix` provides.
- **Undeclared options.** `hardware-fingerprint` and `hardware-profiles`
  set `nixpkgsUnfree.allowed`; `desktop-common` sets `desktop.enable`
  and `deployment.role`. None of them import the modules that declare
  those options.

The builders pass 21 `specialArgs` on NixOS, 14 on Darwin, about 20
through Colmena (a third, hand-synced construction path), and more
through Home Manager's `extraSpecialArgs`. Five are never read. About 15
uses feed an `imports` list, which is why converting them naively to
options recurses.

## Decisions

### `inputs` is the only specialArg

`specialArgs` can feed `imports`; `_module.args` and options cannot.
`inputs` stays a `specialArg` for host-specific code (`hosts/**`,
`modules/monitoring/master/**`), which is the standard flake pattern.
Nothing reachable from an export may use it; the 4.12 check enforces
this, because a bare `nixosSystem` has no `inputs`.

Home Manager's `extraSpecialArgs` becomes `{ inherit inputs; }` for the
same reason, or empty if 4.8 removes its last use.

### Data becomes options in the existing fleet namespaces

The repo already keeps fleet-wide data as options (`shared.*`,
`deployment.*`; see `modules/data/home-network.nix` for the argument).
Converted arguments join them, declared in one new module,
`modules/base/fleet-identity.nix`, with types and descriptions
(`option-schema` check):

| Argument                                                          | Becomes                                        |
| ----------------------------------------------------------------- | ---------------------------------------------- |
| `user`                                                            | `shared.user.name`                             |
| `verbose_name`, `github_email`                                    | `shared.user.fullName`, `shared.user.email`    |
| `extraUsers`                                                      | `shared.extraUsers`                            |
| `agentNodes`, `agentScrapeMap`, `desktopNodes`, `desktopScrapeMap` | `shared.monitoring.*` (same names)             |
| `stateVersion`                                                    | see below                                      |
| `catppuccinWallpapers`                                            | `shared.catppuccinWallpapers` (package option) |

`stateVersion` needs no new option. On Linux the builder sets
`system.stateVersion` itself from the value it already validates
(`check-state-version.nix`), and the 10 host files that do
`system.stateVersion = stateVersion;` drop that line. On both OSes the
Home Manager value arrives through the bridge below. nix-darwin's own
`system.stateVersion` is an unrelated integer the Darwin hosts already
set, and is untouched.

### Home Manager gets its values through a bridge

Home Manager is a separate module system: `config.shared.*` from the
system tree is not visible inside `home-manager.users.<name>`, and the
`homeModules` exports have no system tree at all. So the Home Manager
side declares its own small set of options, in
`modules/base/fleet-identity-home.nix`:

| Home Manager option      | Default                    | Set by the bridge from              |
| ------------------------ | -------------------------- | ----------------------------------- |
| `shared.user.name`       | `config.home.username`     | `shared.user.name`                  |
| `shared.user.fullName`   | none                       | `shared.user.fullName`              |
| `shared.user.email`      | none                       | `shared.user.email`                 |
| `shared.hostSystem`      | none                       | `nixpkgs.hostPlatform.system`       |
| `home.stateVersion`      | (Home Manager's own)       | the builder's validated value       |

The bridge is one entry in `home-manager.sharedModules`, added by the
NixOS and Darwin builders, that copies those values across. Home
Manager modules read `config.shared.*` from their own tree, and use
`lib.hm` for what `hmlib` provided. A standalone `homeModules` consumer
sets the options directly; `shared.user.name` falls back to
`home.username`.

### Values with a native source use it

- `system`: `config.nixpkgs.hostPlatform.system` in system-level
  modules, a plain option value that never forces `pkgs`. That matters
  for `features/shell/nvim`, which deliberately passes nixvim a literal
  platform string because resolving `pkgs.stdenv` there re-enters the
  host evaluation and recurses (see the comment in that file). Home
  Manager modules use the bridged `config.shared.hostSystem`, which is
  the same value.
- `hmlib`: `lib.hm` inside the Home Manager submodule.
- `isDarwin` in `config`: `pkgs.stdenv.hostPlatform.isDarwin`.
- `isDesktop` in `config` (kernel pin): `config.deployment.role == "desktop"`.

### The caller chooses modules; modules don't branch their imports

Every `isDarwin`, `isLinux` or `isDesktop` branch in an `imports` list
is replaced by splitting the file per platform (or per role), with the
builder listing the right half. `modules/base/home-linux.nix` already
works this way. This is the only safe fix: those flags cannot come from
`pkgs` or `config` without recursing.

### External modules are wired by the builder

Modules stop importing flake-input modules (`sops-nix`, `catppuccin`,
Home Manager's Darwin module, `nixvim`, `lan-mouse`, the yazi plugins).
The builder adds them to the module list, and Home Manager ones go in
`home-manager.sharedModules`. Per-host channel selection (stable or
unstable `catppuccin`, `sops-nix`, `nix-yazi-plugins`) then lives only
in the builder, and `catppuccinInput`, `sopsNixInput` and
`nixYaziPluginsInput` disappear.

Packages from inputs come through overlays the builder applies, as
`nixos-needsreboot` already does. The sops-nix package override uses the
module's own `options.sops.package.default` instead of re-importing the
input.

### Colmena derives from mk-system

Colmena's `meta.specialArgs` and `nodeSpecialArgs` collapse to
`{ inherit inputs; }`. Per-host differences move into the per-node
modules `mkSystem` already produces. The existing Colmena parity check
verifies this.

### Exports bring their own dependencies

Each export in `flake.nix` imports what it needs, closing over the
flake's own inputs (`import`-and-apply style, as `needsrebootOverlay`
does now): the declaring modules for every option it sets, the external
modules it configures, and its overlays. Profiles import the feature
modules whose options they set; the module system de-duplicates
repeated imports by path.

### Every subtask is closure-neutral

This is a refactor. Every subtask must leave `scripts/impacted-hosts.sh
--os linux` and `--os darwin` at "no impacted hosts", plus the Colmena
parity, `module-reachability`, `option-schema` and `doc-drift` checks
green. A subtask that changes a closure is wrong, however small the
change.

## Execution model

Strictly sequential. 4.2 is the foundation every migration builds on,
and most subtasks edit the three builders, so concurrent branches would
conflict on them. One branch and PR per subtask, merged in order.

Plan 02 and Plan 03 are in progress. Under `plan-sequencing-discipline`,
4.x PRs can merge as they finish, but Plan 04 cannot be marked complete
until both are.

## Subtasks

Verification for every subtask: `impacted-hosts.sh --os linux origin/main`
and `--os darwin` report no impacted hosts; every host evaluates with no
`evaluation warning:`; `nix build .#checks.x86_64-linux.colmena-parity`
(or the parity script) and pre-commit pass.

- [x] **4.1 Drop dead arguments.** Remove `github_signing_key` and
      `agentTargets` everywhere (no module reads them; they are only
      passed through), and remove `self`, `nixvim`, `niri` and
      `catppuccin` from both Home Manager `extraSpecialArgs` only. Keep
      `self` and `niri` in `sharedArgs`: `mk-system.nix` and
      `flake/hosts/nixos.nix` read them at flake level. Scope:
      `flake.nix`, `flake/lib/mk-system.nix`,
      `flake/lib/mk-darwin-system.nix`, `flake/deployment/colmena.nix`.
- [x] **4.2 Declare the fleet options.** New
      `modules/base/fleet-identity.nix` declaring every option in the
      table above, and `modules/base/fleet-identity-home.nix` with the
      Home Manager options and the `sharedModules` bridge. Import them
      from `modules/base/system.nix`, have all three builders set them
      from the values they already pass, and keep the `specialArgs` for
      now so nothing changes yet. Test: on Daytona, Freds-MacBook-Pro and
      fredvps (for `nik`), the Home Manager values equal the system ones.
- [x] **4.3 Migrate identity consumers, features/desktop.** Every file
      under `features/desktop/` reading `user`, `extraUsers`,
      `verbose_name` or `github_email` reads `config.shared.*` instead
      and drops the argument.
- [x] **4.4 Migrate identity consumers, rest of features/.**
      `features/{ai,common,media,shell,virtualization}/**`.
- [x] **4.5 Migrate identity consumers, modules, profiles and hosts.**
      `modules/**`, `profiles/**`, `hosts/**`; Home Manager modules
      (`home-profiles/**`, `hosts/darwin/*/home.nix`,
      `modules/base/home*.nix`) read the Home Manager-side
      `config.shared.user.*`; of those, `shared.user.name` defaults to
      `home.username` for
      standalone use.
- [x] **4.6 Migrate the rest of the data arguments.** Monitoring
      topology (`prometheus.nix`, `smartctl.nix`); `stateVersion` (the
      builder sets `system.stateVersion`, the 10 Linux host files drop
      their line, and `home-base.nix` relies on the bridge);
      `catppuccinWallpapers`; `system` (from `config.nixpkgs.hostPlatform.system`, nvim
      included, verified on Daytona, maranello and fredvps); `hmlib`
      (`features/desktop/environments/{hyprland,gnome}`); and
      `kernelPkgsInput` (`kernel-pin.nix`, via an overlay-provided
      package set; `isDesktop` from `deployment.role`).
- [x] **4.7 Split platform and role import branches.**
      `modules/base/system.nix`, `modules/base/home.nix`,
      `modules/secrets/sops.nix`, `features/default.nix` (the builder
      lists `features/desktop` and `features/virtualization` for
      desktops), `features/desktop/{yubikey,ghostty,wezterm}`,
      `features/ai/lammacpp`. Each half is unconditionally imported by
      the caller that needs it, and is reachable for
      `module-reachability`. Remaining `isDarwin` config uses move to
      `pkgs.stdenv.hostPlatform`.
- [x] **4.8 Builder-wired external modules.** Move the `sops-nix`,
      `catppuccin`, Home Manager Darwin, `nixvim`, `lan-mouse` and
      yazi-plugin imports into the builders (`home-manager.sharedModules`
      for Home Manager), including `hosts/linux/fredvps/nik-home.nix`.
      Input packages (`freminal`) via overlays. Drop
      `catppuccinInput`, `sopsNixInput`, `nixYaziPluginsInput`.
- [x] **4.9 Reduce the builders to `inputs`.** NixOS, Darwin, Colmena
      and both Home Manager paths pass only `inputs`. Every remaining
      reader of a removed argument has been migrated, so this is
      deletion only.
- [ ] **4.10 Exports bring their dependencies.** Rework `nixosModules`
      and `homeModules` in `flake.nix` per the decision above, and fix
      `profiles/desktop.nix` to import `features/desktop`, and the
      hardware exports to import `modules/base/nixpkgs-unfree.nix`.
      Decide at activation (raised in review on #2824): the exports
      currently bundle third-party modules such as sops-nix's, which
      conflicts ("already declared") with a consumer that imports its own
      revision of the same module. Choose between bundling (simplest for a
      standalone consumer), letting the consumer supply them (each export
      documents what it needs), or offering both.
- [ ] **4.11 Make `nixosModules.default` coherent.** It combines both
      profiles. Either it evaluates standalone once 4.10 lands, or it is
      redefined as the set that does (decide from 4.10's result, before
      starting 4.11).
- [ ] **4.12 Standalone export check.** `exports-standalone` in
      `flake/dev/checks.nix`: evaluate every `nixosModules.*` attr in a
      bare `nixosSystem` (minimal stub: host platform, root filesystem,
      `stateVersion`) and every `homeModules.*` attr in a bare Home
      Manager configuration, keyed off `lib.attrNames` so new exports
      are covered automatically. Fails on today's `main`; passes after
      4.10-4.11.
- [ ] **4.13 Documentation.** `MODULES.md` (exports are standalone;
      what each one brings), `agents.md` (the "`inputs` is the only
      specialArg" rule), and a short note in `flake/lib/mk-system.nix`.

### Cleanup

- [ ] **4.14 The gnome environment no longer evaluates.** Surfaced during
      4.6 (verifying its `hmlib` change, by enabling
      `desktop.environments.gnome` on Daytona). Two pre-existing failures,
      identical on `main`: `services.upower.enable` conflicts
      (`features/desktop/environments/common.nix` sets `true`, nixpkgs'
      gnome module sets `false`), and the feature references
      `gnome-photos`, which nixpkgs removed. Impact: none today (gnome is
      off on every host), but `desktop.environments.gnome.enable = true`
      cannot be used. Fix: decide whether to keep the gnome environment;
      if so, make common.nix's upower setting `lib.mkDefault` and drop or
      replace `gnome-photos` (nixpkgs suggests `loupe` or `shotwell`).
      Verification: Daytona with gnome enabled evaluates its toplevel.
      Not scheduled against this plan's subtasks; independent.

## Out of scope

- Changing what any host builds. Every subtask is closure-neutral.
- Publishing the exports for outside use (versioning, a changelog).
  This plan makes them work; whether anyone else consumes them is a
  separate decision.
- The `homeModules` beyond `home-desktop` / `default`. They are already
  close to self-contained (they need only `user`); 4.5 and 4.12 cover
  them.
