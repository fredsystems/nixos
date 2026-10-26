# Plan 01: Noctalia desktop shell

- **Status:** in progress
- **Branch:** `feat/noctalia-shell`
- **Scope of the current run:** subtasks 1.1 through 1.12 (phases 0-2).
  Phase 3 (remove wayle) and phase 4 (greeter) are deliberately not
  started until the trial on Daytona is signed off.

## Goal

Replace the hand-assembled desktop shell (wayle bar/OSD/notifications/
wallpaper, plus hypridle, hyprsunset, polkit-gnome and cliphist) with
[Noctalia](https://github.com/noctalia-dev/noctalia) on the Hyprland and
niri desktops, keeping Catppuccin Mocha as the system theme. Roll it out
one host at a time behind a single option so the old stack keeps working
until the new one is proven.

## Decisions

| Topic           | Decision                                                                                   |
| --------------- | ------------------------------------------------------------------------------------------ |
| Source          | `pkgs.noctalia` from our pinned nixpkgs and home-manager's `programs.noctalia`. No input.  |
| Theme           | Noctalia's built-in `Catppuccin` palette (Mocha, mauve primary). No custom palette.        |
| System accent   | Changed fleet-wide from lavender to mauve so the shell and every other port agree.         |
| App templates   | Noctalia's GTK/terminal templates stay off; catppuccin/nix owns app theming.               |
| Wallpaper       | Per-monitor independent no-repeat rotation, recursive over `~/Pictures/Background`, 5 min. |
| Rollout         | `desktop.environments.shell.provider` enum; Daytona = `noctalia`, maranello = `wayle`.     |
| Launcher        | vicinae stays. Noctalia's launcher is available but not bound.                             |
| Tray apps       | nm-applet, blueman, udiskie, syncclipboard and solaar keep running in the tray.            |
| Clipboard       | Noctalia's clipboard history on Noctalia hosts; cliphist + fuzzel on wayle hosts.          |
| Lock screen     | Noctalia's lock screen on Noctalia hosts. It authenticates against the `login` PAM stack.  |
| Login manager   | SDDM stays until phase 4.                                                                  |
| Config drift    | GUI changes land in `~/.local/state/noctalia/settings.toml` and override Nix. Delete it to reset. |

### Why the wallpaper choice matters

wayle-wallpaper 0.1.3 in independent-shuffle mode picks
`rand::random_range(0..image_count)` on every tick with no memory, so a
1,247-image library has even odds of a repeat within about 42 picks per
monitor, and nothing survives a restart. Noctalia's
`wallpaper::ShuffleState` keeps a per-scope "seen" set, never repeats
until every candidate has been shown, and persists that set in
`~/.local/state/noctalia/wallpaper_shuffle.json`. With
`per_monitor_directories = true` each connector gets its own scope.

### PAM consequence of the Noctalia lock screen

Noctalia's lock screen always uses the `login` PAM service and drives
fprintd itself over D-Bus. The existing `hyprlock.u2fAuth` setting
therefore does not apply. On Noctalia hosts with
`hardware-profile.u2f.enable`, `login.u2fAuth` is enabled instead. That
also lets a security key satisfy a text-console login on those hosts.

## Subtasks

Each subtask is one commit and leaves `./scripts/impacted-hosts.sh --os
linux --eval` green.

### Phase 0: accent

- [ ] **1.1 Switch the catppuccin accent to mauve.**
  - Files: `modules/base/catppuccin.nix`, `modules/base/home.nix`,
    `features/desktop/environments/common.nix` (SDDM cursor theme name,
    `catppuccin-cursors.mochaMauve`, comment),
    `features/desktop/environments/modules/wayle/default.nix` (palette
    `primary`).
  - Impact: every host's closure changes (fleet-wide deploy).

### Phase 1: Noctalia beside wayle

- [ ] **1.2 Shell selection interface.** New
  `features/desktop/environments/shell/default.nix` declaring
  `desktop.environments.shell.provider` (`wayle` | `noctalia`, default
  `wayle`), the session-start lists (`startupUnits`, `startupCommands`)
  and the compositor-facing `commands` (volume, mute, mic mute, idle
  inhibit). Imported from `features/desktop/environments/default.nix`.
- [ ] **1.3 Extract shell-agnostic scripts.** Move the compositor-aware
  logout/reboot/poweroff wrappers and the deploy-state script out of the
  wayle module into `shell/session-actions.nix` and
  `shell/nixos-deploy-state.nix`, exposed as read-only package options.
  wayle consumes them from there; behaviour is unchanged.
- [ ] **1.4 wayle owns its half of the interface.**
  `modules/default.nix` enables wayle only when `provider = "wayle"`;
  the wayle module sets `startupUnits`, `startupCommands` and
  `commands`.
- [ ] **1.5 Compositors consume the interface.**
  `hyprland/default.nix` and `niri/default.nix` render their autostart
  and the volume / mute / idle-inhibit binds from
  `desktop.environments.shell` instead of hard-coding wayle.
- [ ] **1.6 Noctalia module.** New `modules/noctalia/default.nix`:
  bar mirroring the wayle layout, notifications, OSD (following the
  focused output), wallpaper rotation, session actions bound to the
  shared scripts, Catppuccin theme, templates off. Sets its half of the
  interface. Config is validated at build time by `noctalia config
  validate`.
- [ ] **1.7 Deploy-state bar widget.** New
  `modules/noctalia/plugins/nixos-deploy-state/` (`plugin.toml`,
  `widget.luau`) polling the shared script every 60 s, installed as a
  read-only `path` plugin source.
- [ ] **1.8 Select Noctalia on Daytona.**
  `hosts/linux/daytona/configuration.nix` sets
  `desktop.environments.shell.provider = "noctalia"`.

### Phase 2: Noctalia absorbs the helper daemons (Noctalia hosts only)

- [ ] **1.9 Lock screen.** `pauseandsleep.sh` locks via
  `loginctl lock-session` (handled by hypridle on wayle hosts and by
  Noctalia's logind integration on Noctalia hosts). Noctalia module
  enables `login.u2fAuth` when the host uses U2F.
- [ ] **1.10 Idle.** hypridle only on wayle hosts; Noctalia gets
  lock 300 s, monitors off 600 s, suspend 900 s.
- [ ] **1.11 Night light.** hyprsunset only on wayle hosts; Noctalia
  night light on a fixed 07:30 / 18:00 schedule at 6500 K / 5000 K.
- [ ] **1.12 Clipboard and polkit.** The cliphist watchers and fuzzel
  `SUPER+V` bind only on wayle hosts; Noctalia hosts bind `SUPER+V` to
  Noctalia's clipboard panel. polkit-gnome is started only on wayle
  hosts; Noctalia hosts use Noctalia's polkit agent.

## Trial checklist (Daytona, user-run)

- [ ] Bar, tray icons, notifications and OSD behave; OSD follows focus.
- [ ] Logout, reboot and poweroff from the session panel close apps
      cleanly under Hyprland (hyprshutdown) and niri.
- [ ] Deploy-state widget shows the right state and tooltip.
- [ ] Lock, unlock by password, fingerprint and security key.
- [ ] Idle lock, monitors off and suspend fire at the right times;
      caffeine (`SUPER+S`) blocks them.
- [ ] Night light switches at 18:00 and 07:30.
- [ ] Wallpapers never repeat. `jq '[.scopes[][] | length]'
      ~/.local/state/noctalia/wallpaper_shuffle.json` only grows, and
      `journalctl --user -u noctalia | grep 'automation set' | awk
      '{print $NF}' | sort | uniq -d` prints nothing.

## Phase 3: remove wayle (after the trial)

Not started. Switch maranello to Noctalia first, then:

- Delete `features/desktop/environments/modules/wayle/` (module, three
  icons, `styles/index.scss`).
- Remove the wayle import and branch from
  `features/desktop/environments/modules/default.nix`, and collapse the
  `provider` option and every `provider == "wayle"` branch in
  `common.nix`, `modules/clipboard/default.nix`, `hyprland/default.nix`,
  `niri/default.nix` and `shell/default.nix`.
- Remove `wayleMonitor` and `isLaptop` (only wayle reads them) from
  `flake/lib/mk-system.nix` and `flake/hosts/nixos.nix`.
- Remove the `Pictures/Background-flat` entry from
  `features/desktop/environments/default.nix` and the flat-mirror step
  from `flake/dev/packages.nix`.
- Drop hypridle, hyprsunset, polkit-gnome, `hyprpolkitagent`, cliphist
  and the `hyprextra/scripts/dpms.sh` and `logout.sh` scripts.
- Fix wayle mentions in `features/desktop/clipboard/default.nix`,
  `overlays/syncclipboard.nix`, `hyprextra/scripts/backlight.sh`,
  `hyprextra/scripts/kbbacklight.sh` and `hyprlandextra/default.nix`.

## Phase 4: noctalia-greeter (after phase 3)

Not started. Replace SDDM with `services.displayManager.noctalia-greeter`
(greetd):

- `common.nix`: SDDM and `catppuccin.sddm` blocks; add
  `security.pam.services.greetd.enableGnomeKeyring` and any U2F setting.
- `hosts/linux/daytona/configuration.nix`: remove the
  `sddm-hyprland-config` activation script.
- `hosts/linux/maranello/configuration.nix`: replace the SDDM block,
  `CompositorCommand` and activation script with the greeter's
  `[output]` layout generated from `monitors.nix`.
