# Plan 01: Noctalia desktop shell

- **Status:** pending merge (subtasks 1.1-1.25 committed; trial on both
  desktops pending)
- **Branches:** `feat/noctalia-shell` (1.1-1.12, merged),
  `feat/noctalia-compositor-settings` (1.13-1.25)

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
| Rollout         | Daytona first behind a `provider` enum, then maranello; the enum went with wayle (1.20).   |
| Launcher        | vicinae stays on ALT+Space. Noctalia's launcher is on SUPER+Space.                         |
| Tray apps       | nm-applet, blueman, udiskie, syncclipboard and solaar keep running in the tray.            |
| Clipboard       | Noctalia's clipboard history (SUPER+V).                                                    |
| Lock screen     | Noctalia's lock screen. It authenticates against the `login` PAM stack.                    |
| Login manager   | noctalia-greeter on greetd. Its PAM service substacks `login`.                             |
| Keybinds        | One table in the Noctalia module, rendered for Hyprland and niri. Caffeine is SUPER+SHIFT+S. |
| Control center  | 1000 px wide, labelled sidebar, floats below the bar; opens under a clicked bar widget.    |
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
linux --eval` green. 1.9 and 1.10 landed as one commit, because either
half alone leaves a window with two lockers or none; 1.12 landed as two
(clipboard, then polkit).

### Phase 0: accent

- [x] **1.1 Switch the catppuccin accent to mauve.**
  - Files: `modules/base/catppuccin.nix`, `modules/base/home.nix`,
    `features/desktop/environments/common.nix` (SDDM cursor theme name,
    `catppuccin-cursors.mochaMauve`, comment),
    `features/desktop/environments/modules/wayle/default.nix` (palette
    `primary`).
  - Impact: every host's closure changes (fleet-wide deploy).

### Phase 1: Noctalia beside wayle

- [x] **1.2 Shell selection interface.** New
  `features/desktop/environments/shell/default.nix` declaring
  `desktop.environments.shell.provider` (`wayle` | `noctalia`, default
  `wayle`), the session-start lists (`startupUnits`, `startupCommands`)
  and the compositor-facing `commands` (volume, mute, mic mute, idle
  inhibit). Imported from `features/desktop/environments/default.nix`.
- [x] **1.3 Extract shell-agnostic scripts.** Move the compositor-aware
  logout/reboot/poweroff wrappers and the deploy-state script out of the
  wayle module into `shell/session-actions.nix` and
  `shell/nixos-deploy-state.nix`, exposed as read-only package options.
  wayle consumes them from there; behaviour is unchanged.
- [x] **1.4 wayle owns its half of the interface.**
  `modules/default.nix` enables wayle only when `provider = "wayle"`;
  the wayle module sets `startupUnits`, `startupCommands` and
  `commands`.
- [x] **1.5 Compositors consume the interface.**
  `hyprland/default.nix` and `niri/default.nix` render their autostart
  and the volume / mute / idle-inhibit binds from
  `desktop.environments.shell` instead of hard-coding wayle.
- [x] **1.6 Noctalia module.** New `modules/noctalia/default.nix`:
  bar mirroring the wayle layout, notifications, OSD (following the
  focused output), wallpaper rotation, session actions bound to the
  shared scripts, Catppuccin theme, templates off. Sets its half of the
  interface. Config is validated at build time by `noctalia config
  validate`.
- [x] **1.7 Deploy-state bar widget.** New
  `modules/noctalia/plugins/nixos-deploy-state/` (`plugin.toml`,
  `widget.luau`) polling the shared script every 60 s, installed as a
  read-only `path` plugin source.
- [x] **1.8 Select Noctalia on Daytona.**
  `hosts/linux/daytona/configuration.nix` sets
  `desktop.environments.shell.provider = "noctalia"`.

### Phase 2: Noctalia absorbs the helper daemons (Noctalia hosts only)

- [x] **1.9 Lock screen.** `pauseandsleep.sh` locks via
  `loginctl lock-session` (handled by hypridle on wayle hosts and by
  Noctalia's logind integration on Noctalia hosts). Noctalia module
  enables `login.u2fAuth` when the host uses U2F.
- [x] **1.10 Idle.** hypridle only on wayle hosts; Noctalia gets
  lock 300 s, monitors off 600 s, suspend 900 s.
- [x] **1.11 Night light.** hyprsunset only on wayle hosts; Noctalia
  night light on a fixed 07:30 / 18:00 schedule at 6500 K / 5000 K.
- [x] **1.12 Clipboard and polkit.** The cliphist watchers and fuzzel
  `SUPER+V` bind only on wayle hosts; Noctalia hosts bind `SUPER+V` to
  Noctalia's clipboard panel. polkit-gnome is started only on wayle
  hosts; Noctalia hosts use Noctalia's polkit agent.

### Phase 2b: compositor settings and control center

- [x] **1.13 Noctalia's recommended Hyprland settings** (user commit):
  gaps 5/10, shadow range 4, blur, the IPC binds and the settings-window
  and layer rules.
- [x] **1.14 Share the binds between compositors.** The launcher,
  control-center, clipboard, settings and window-switcher binds and the
  settings-window rule move into the Noctalia module, rendered for both
  Hyprland and niri. Caffeine moves from SUPER+S to SUPER+SHIFT+S.
- [x] **1.15 niri appearance.** 20 px rounded, clipped corners (and
  `rounding = 20` in Hyprland), gaps 10, blur behind windows, xray off
  on Noctalia's surfaces, blur on the window switcher.
- [x] **1.16 Stationary wallpaper under niri.** `noctalia-wallpaper` is
  placed in niri's backdrop, the workspace background is transparent and
  overview workspace shadows are off. Noctalia's `[backdrop]` stays off.
- [x] **1.17 Brightness keys** call `noctalia msg brightness-up/down`
  and show its OSD, in both compositors.
- [x] **1.18 Type-to-launch** in niri's overview.
- [x] **1.19 Control center.** 1000 px wide with the labelled sidebar,
  floating below the bar, under the clicked widget from a bar click.
  In Hyprland, panels opened by keybind (SUPER+S, SUPER+Space, SUPER+V)
  move the pointer to their centre via a `layer.opened` hook.

### Phase 3: remove wayle

- [x] **1.20 Switch maranello to Noctalia.**
- [x] **1.21 Remove wayle and the `provider` option.** Deletes the
  wayle module and every wayle branch, including hypridle, hyprsunset,
  the polkit-gnome agent and the cliphist watchers.
- [x] **1.22 Drop `isLaptop` and `wayleMonitor`** from the system
  builder (closures unchanged).
- [x] **1.23 Drop the flat wallpaper mirror**
  (`~/Pictures/Background-flat` and its build step).
- [x] **1.24 Remove leftovers**: hypridle, hyprpolkitagent and
  polkit-gnome packages, their PAM services, and the `dpms.sh`,
  `logout.sh` and `backlight.sh` scripts. Remaining wayle mentions are
  reworded.

### Phase 4: noctalia-greeter

- [x] **1.25 Replace SDDM with noctalia-greeter.** Catppuccin scheme
  (pinned), mauve cursor, SF Pro font, opens on `fred`'s password step
  and remembers the last session. greetd's PAM substacks `login`, so
  gnome-keyring, U2F and Daytona's fingerprint opt-out need no greetd
  entries. Empty-password submit starts the security-key prompt. The
  shell may sync wallpaper and layout without an admin prompt.
  maranello's `[output]` layout, scales and refresh rates come from
  `monitors.nix` via `modules/compositors/noctalia-greeter.nix`.

## Trial checklist (both desktops, user-run)

- [ ] Bar, tray icons, notifications and OSD behave; OSD follows focus.
- [ ] Logout, reboot and poweroff from the session panel close apps
      cleanly under Hyprland (hyprshutdown) and niri.
- [ ] Deploy-state widget shows the right state and tooltip.
- [ ] Lock, unlock by password, fingerprint and security key.
- [ ] Idle lock, monitors off and suspend fire at the right times;
      caffeine (`SUPER+SHIFT+S`) blocks them.
- [ ] Night light switches at 18:00 and 07:30.
- [ ] `SUPER+V` opens Noctalia's clipboard history, and history survives a
      reboot (its key lives in gnome-keyring's default collection).
- [ ] An admin prompt (for example `pkexec true`) appears as a Noctalia
      panel and accepts password, fingerprint and security key.
- [ ] Wallpapers never repeat. `jq '[.scopes[][] | length]'
      ~/.local/state/noctalia/wallpaper_shuffle.json` only grows, and
      `journalctl --user -u noctalia | grep 'automation set' | awk
      '{print $NF}' | sort | uniq -d` prints nothing.
- [ ] `SUPER+S` opens the control center centred under the bar and, in
      Hyprland, moves the pointer onto it; a bar click opens it under
      the widget and leaves the pointer alone.
- [ ] Brightness keys change the backlight and show the OSD (maranello
      needs `[brightness] enable_ddcutil` for its monitors).
- [ ] niri: rounded corners, blur, a stationary wallpaper, and typing in
      the overview opens the launcher.
- [ ] The greeter appears on every monitor (maranello in the 2x2
      layout), logs in by password and by security key, and the
      keyring unlocks.

## Known limitations

- `noctalia config validate`, which home-manager runs at build time,
  exits 0 on warnings. An unknown or misspelled key therefore builds
  and is silently ignored. Run the validator by hand after editing the
  settings and read its output.
- The deploy-state widget's Luau has been syntax-checked and the config
  recognises it, but it first runs for real on Daytona.
- Noctalia 5.3.0 places a panel from config only; `panel-toggle` takes
  no position, so a keybind cannot open the control center somewhere
  other than where a bar click would.
- niri has no action to move the pointer, so keybind-opened panels do
  not get the pointer there as they do under Hyprland.
- `niri_overview_close_on_launch_enabled` from Noctalia's niri guide
  does not exist in 5.3.0 and is not set.
