---
name: nixos-stable-channel-bump
description: Use ONLY in the fred/nixos flake repo when (a) writing a module that must emit different config on stable vs unstable because an option exists on only one channel (a "channel gate"), (b) handling the Renovate "nixos stable channel" group PR or otherwise moving nixpkgs-stable / nixpkgs-kernel / home-manager-stable / catppuccin-stable to a new NixOS release (e.g. 26.05 -> 26.11), or (c) the `channel-gates` or `stable-channel-consistency` flake check fails, or FlakeInputOnSupersededChannel / FlakeInputOnEolChannel fires. Covers the modules/lib/channel-gates.nix registry and its removeAt expiry, why gates test option presence and never a release string, why stateVersion-keyed defaults are not channel gates, Renovate's piecemeal group PR, and the release-bump checklist.
---

# NixOS: channel gates and the stable release bump

Servers build from the stable release (`nixpkgs-stable`,
`home-manager-stable`, `catppuccin-stable`, plus the `nixpkgs-kernel`
`-small` channel). Desktops and Darwin build from unstable. Between two
stable releases the fleet straddles every option rename that landed on
unstable in the meantime, and modules shared by both have to cope. Twice a
year the stable side catches up and that compatibility code must go.

Two flake checks make both halves mechanical. They live in
`flake/dev/channel-checks.nix` and run in `lint.yaml` on every PR:

| Check                        | Fails when                                                                          |
| ---------------------------- | ----------------------------------------------------------------------------------- |
| `stable-channel-consistency` | The four stable channel inputs are not all on one release.                          |
| `channel-gates`              | A gate expired, a gate is not live, the registry drifted, or an ad-hoc gate exists. |

## Writing a channel gate

Register it in `modules/lib/channel-gates.nix`, then test it by id:

```nix
let
  channelGates = import ../lib/channel-gates.nix; # relative path
in
{
  services.foo =
    if channelGates.available "foo-settings" options then
      { settings.Bar = 1; }
    else
      { extraConfig = "Bar=1"; };
}
```

Registry entry:

```nix
foo-settings = {
  tree = "nixos"; # or "home-manager" for a home-manager user's options
  option = [ "services" "foo" "settings" ];
  removeAt = "26.11"; # first stable release that declares the option
};
```

Rules:

- **Test option presence, never a release string.** No
  `lib.trivial.release`, `system.nixos.release`, `home.version.release`,
  `lib.version`, or "am I on stable" flag. Presence is what the code
  actually depends on, and it flips by itself when stable moves. The
  check rejects release reads and any inline `options ? ...` outside the
  registry.
- **`removeAt` is the first stable release whose channel declares the
  option.** If the option is already on unstable, that is the next stable
  release, because unstable becomes it at branch-off. Confirm against the
  nixpkgs `release-YY.MM` branch once it exists.
- **Use `options` from the right tree.** In a home-manager module
  (`home-manager.users.<n> = { options, ... }: ...` or a `homeModules`
  file), `options` is the home-manager tree; set `tree = "home-manager"`.
- **Put a pointer comment at each call site** naming the gate id and
  saying which branch goes when it expires.

### Not a channel gate

- **stateVersion-keyed defaults.** home-manager's
  `mkStateVersionOptionDefault` options (`programs.yazi.shellWrapperName`,
  `xdg.userDirs.setSessionVariables`) change their default by
  `home.stateVersion`, not by release. Several hosts sit on 25.x
  stateVersions that are never bumped, so the explicit setting is
  permanent. Set it unconditionally and say why.
- **Upstream bugs.** A workaround waiting on an upstream fix belongs in
  `.github/tracked-upstream-fixes.json`; see `nixos-track-upstream-fix`.
  A channel gate is about API drift between two healthy channels.
- **Probing an input's source files** (`builtins.pathExists` on a module
  path, `readFile` + `hasInfix`). It is invisible to the check and
  silently goes dead. Express it as an option-presence gate instead.

## What `channel-gates` enforces

For each registered gate, using one stable and one unstable host (picked
by which nixpkgs they are built from, not by name):

1. **Expired**: the locked `nixpkgs-stable` release is at or past
   `removeAt`. Delete the fallback branch at every call site and the
   registry entry. This is what turns the release bump PR red until the
   cleanup is in it.
2. **Dead early**: the option is already on stable before `removeAt`
   (backport, or wrong `removeAt`). Remove it now, or fix `removeAt`.
3. **Wrong**: the option is not on unstable either. Unstable renamed it
   again; rework the gate.
4. **Unreferenced**: an id with no `available "<id>"` call outside a
   comment. Delete the entry.
5. **Ad-hoc**: a presence test outside the registry (`options ? a.b`,
   `options.a.b or <default>`, `hasAttrByPath ... options`) or a release
   read. Register a gate.

An unknown id at a call site is an evaluation error.

## The release bump

### Timeline

1. **Branch-off (beta)**, a few weeks before release: nixpkgs creates
   `release-YY.MM` and `nixos-YY.MM-small`. The `nixos-YY.MM` channel does
   not exist yet. Renovate proposes only `nixpkgs-kernel` (its regex keeps
   the `-small` suffix). **Do not merge it alone**;
   `stable-channel-consistency` fails it anyway.
2. **Release day**: `nixos-YY.MM` appears and Renovate adds
   `nixpkgs-stable` to the group PR. prometheus.nixos.org marks the old
   release `deprecated`, so FlakeInputOnSupersededChannel fires (info).
3. **Days to weeks later**: home-manager and catppuccin cut
   `release-YY.MM`; Renovate adds each to the group PR as it appears.
   Home Manager's own release check also fails CI while it is the odd one
   out (a release-mismatch evaluation warning).
4. **About a month after release**: the old release goes `unmaintained`
   and FlakeInputOnEolChannel fires (warning). Be done before this.

Renovate's group (`.github/renovate.json5`, "nixos stable channel") only
contains the members that have an update at the moment it runs, which is
why the PR fills in piecemeal. It is `automerge: false`, and
`renovate-relock.yaml` re-locks the branch after each Renovate push.

### Landing it

Once all four members are in the group PR and `stable-channel-consistency`
passes:

1. **Fix what `channel-gates` reports.** Every gate with
   `removeAt = YY.MM` is now expired: keep the new-option branch, delete
   the fallback and the registry entry. Commit on the Renovate branch (or a
   branch from it). Renovate stops rebasing a branch with foreign commits,
   which is what you want once the group is complete.
2. **Read the release notes' "Backward Incompatibilities"** for NixOS and
   Home Manager. Anything renamed emits an evaluation warning, which fails
   CI's server builds, so most of it surfaces on its own.
3. **Never touch a `stateVersion`** (`flake/hosts/servers.nix`,
   `home.stateVersion`). A release bump is not a stateVersion bump.
4. **Update prose that names releases**: `rg -n 'YY\.MM'` for the old and
   new release, and fix comments such as "servers on stable 26.05" in
   modules touched by the gates.
5. **Check `fredhub`'s one unstable package**: it may now be in stable.
6. **Check `.github/tracked-upstream-fixes.json`** entries with
   `pin_node: nixpkgs-stable` or a server `eval_host`; the bump may
   resolve them.
7. **Verify**: `./scripts/impacted-hosts.sh --os linux --eval` (expect
   every server), plus `nix build` of `channel-gates`,
   `stable-channel-consistency` and `exports-standalone`.

### Deploying it

- Every server closure changes; CI builds them all and fills Attic.
- The kernel stays on the 6.18 line but is rebuilt, so **every server
  needs a reboot**. Plan a window, and deploy with colmena rather than
  letting servers pick it up piecemeal.
- Expect service restarts wherever a gate switched dialect (journald
  restarts when its config moves from `extraConfig` to `settings`).
- nvrhub's NVIDIA module is built from the kernel tree, so check
  `nvidia-smi` there after the reboot.

## Monitoring

github-ci-exporter reads each input's channel from `flake.lock` every hour,
so a renamed ref is picked up with no change here. It also maps
`release-YY.MM` branches of home-manager and catppuccin onto
`nixos-YY.MM`, so FlakeInputOnSupersededChannel and FlakeInputOnEolChannel
cover them as well as nixpkgs. The flake-inputs dashboard's channel table
shows each followed channel's upstream status.

## When to stop and ask

- `removeAt` cannot be determined because upstream has not decided which
  release carries the option. Do not guess low: an early expiry fails CI
  on a release that still needs the fallback.
- A gate needs a condition other than option presence (behaviour changed
  under the same option name). Surface it before adding an exemption to
  the check.
- The group PR is complete but home-manager or catppuccin's release branch
  is not yet usable (broken eval upstream). Holding the bump is fine until
  EOL is close; pinning one member to a commit needs a decision.
