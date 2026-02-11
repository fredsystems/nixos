# NixOS Configuration Flake

![Hyprland](hyprland.png "NixOS with Hyprland")

## Overview

This repository contains **my personal NixOS configuration**, built
around:

- **Nix Flakes**
- **Home Manager**
- **Hyprland / GNOME**
- A shared set of dotfiles for both **NixOS** and **non-NixOS**
  machines (e.g., macOS)

It is designed primarily for my own systems, but it can serve as a
**reference or starting point** if you are building your own flake-based
NixOS setup.

**NEW**: This flake now exports reusable `nixosModules` and `homeModules`
that can be used in other flakes. See [MODULES.md](./MODULES.md) for
documentation on using these modules in your own configurations.

## Systems Included

The main entry point is [`flake.nix`](./flake.nix).

It defines several host configurations:

| System Name           | Description           | Profile                                                    |
| --------------------- | --------------------- | ---------------------------------------------------------- |
| **Daytona**           | Personal laptop       | Desktop + Extra Packages + Development                     |
| **Maranello**         | Home workstation      | Desktop + Extra Packages + Games + Streaming + Development |
| **acarshub**          | Server                | Server + Development                                       |
| **vdlmhub**           | Server                | Server + Development                                       |
| **hfdlhub-1**         | Server                | Server + Development                                       |
| **hfdlhub-2**         | Server                | Server + Development                                       |
| **Freds-Macbook-Pro** | Personal macOS laptop | Development/Darwin                                         |

## Using This Configuration (If You Really Want To)

This is mostly here for my own machines---but if you want to adopt it:

1. Install NixOS (graphical installer recommended --- GNOME works
   fine).
2. Clone this repo into your home directory.
3. In `flake.nix`, remove all systems except **maranello**.
4. Rename `maranello` to your desired hostname.
5. Rename `system/maranello` → `system/<your system name>`.
6. Copy your generated `/etc/nixos/hardware-configuration.nix` into
   that directory.
7. In `flake.nix`, update the `{nixos|darwin}Configurations.<system>` entry to
   point to your renamed system directory. Each of the `mk{Nixos|Darwin}System` has some global configuration options.
   The name documents what they do, and you will want to change them.
   Very likely, you will want to ALSO set the `stateVersion` to the most recent NixOS release which at this current time is `25.05`.
8. Build and switch:

```bash
sudo nixos-rebuild switch --flake .#<system name>
```

> [!IMPORTANT]
> `flake.nix` has the configuration options to allow you to dynamically set your username and a few other options to customize this to your needs.
> That said, if you look in the dotfiles directory I have custom scripts for myself that hard code paths in them.
> You will, obviously, need to audit these files because they're bespoke to my needs. Most of these can probably be nuked without issue.

### Optional Post-Install Steps

- Authenticate GitHub:

  ```bash
  gh auth login
  ```

- Bring in any extra dotfiles:

  ```bash
  stow -vt ~ *
  ```

- Install SSH keys into `~/.ssh` and run `ssh-add`.

- Fix VS Code keyring integration by adding:

  ```json
  "password-store": "gnome"
  ```

  to `~/.vscode/argv.json`.

- In Neovim, authenticate GitHub Copilot:

```bash
      :Copilot auth
```

## Configurable Options

Each system's `configuration.nix` supports these options:

| Option                     | Description                                             | Default |
| -------------------------- | ------------------------------------------------------- | ------- |
| `desktop.enable`           | Enables the desktop environment                         | `false` |
| `desktop.enable_extra`     | Installs "extra" packages (some may fail on aarch64 VM) | `false` |
| `desktop.enable_games`     | Installs Steam and related gaming packages              | `false` |
| `desktop.enable_streaming` | Installs OBS and streaming-related packages             | `false` |

## Using Exported Modules

This flake exports reusable NixOS and Home Manager modules. To use them in your own flake:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    fredsystems.url = "github:FredSystems/nixos";
  };

  outputs = { nixpkgs, fredsystems, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        fredsystems.nixosModules.github-runners
        fredsystems.nixosModules.hardware-graphics
        ./configuration.nix
      ];
    };
  };
}
```

Available modules include:

- **Profiles**: `desktop-common`, `adsb-hub`
- **Hardware**: `hardware-graphics`, `hardware-i2c`, `hardware-fingerprint`, etc.
- **Services**: `github-runners` (self-hosted GitHub Actions runners)
- **Shared**: `nas-mounts`, `wifi-networks`, `sync-hosts`

See [MODULES.md](./MODULES.md) for complete documentation.

## Caveats

> [!WARNING]
> This is **not** a pure-Nix, perfectly-immutable setup.
>
> Some development tools are installed **system-wide** to make tools
> like `lazygit` work cleanly.
> Several optional post-install steps are still **imperative**, and
> should ideally be baked into declarative modules in the future.
>
> I am migrating all of my git repositories to include a `flake.nix`, and when that happens I will be able to remove a lot of the imperative steps.

## Included Packages (Partial List)

### Graphical Environments

- `GNOME`
- `Hyprland`
- `Cosmic`
- `Niri`

#### Hyprland/Niri Tools

- `fredbar`
- `vicinae`
- `cliphist`
- `wl-clipboard`

### Graphical Applications

#### Browsers

- `Firefox`
- `Brave`
- `Ladybird`

#### Terminals

- `Alacritty`
- `Ghostty`
- `WezTerm` _(default)_
- `iTerm2` (darwin only)

#### Editors

- `Neovim`
- `Zed`
- `VS Code`
- `Sublime Text`

#### Media

- `VLC`
- `multiviewer`
- `obs-studio`
- `streamcontroller`

#### Office

- `LibreOffice`

### Social

- `Discord`

### Shells

- `bash`
- `Zsh` _(default)_

### CLI Tools

- `bat`
- `eza`
- `fastfetch`
- `fd`
- `fzf`
- `gnupg`
- `lazygit`
- `oh-my-zsh`
- `starship`
- `yazi`
- `zoxide`
