# FredSystems NixOS Modules

This flake exports reusable NixOS and Home Manager modules that can be used in other flakes.

## Usage

Add this flake as an input to your `flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    fredsystems.url = "github:FredSystems/nixos";
  };

  outputs = { self, nixpkgs, fredsystems, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        # Use specific modules
        fredsystems.nixosModules.github-runners
        fredsystems.nixosModules.hardware-graphics

        # Or import all modules
        fredsystems.nixosModules.default

        ./configuration.nix
      ];
    };
  };
}
```

## Available NixOS Modules

### Profiles

#### `nixosModules.desktop-common`

Common desktop environment baseline configuration. Enables:

- Hardware support (graphics, i2c, fingerprint, U2F, etc.)
- Desktop services (pipewire, printing, etc.)
- Common desktop packages
- Niri compositor support
- Solaar for Logitech devices

**Options:**

- `desktop.enable` - Enable desktop profile (default: `true` via `mkDefault`)

**Example:**

```nix
{
  imports = [ fredsystems.nixosModules.desktop-common ];

  # Override if needed
  desktop.enable = true;
}
```

#### `nixosModules.adsb-hub`

Baseline configuration for ADSB/monitoring server systems. Includes:

- Monitoring agent configuration
- Server baseline packages
- Optional desktop support (disabled by default)

**Options:**

- `desktop.enable` - Enable desktop on ADSB hub (default: `false` via `mkDefault`)

### Hardware Profiles

#### `nixosModules.hardware-profiles`

Bundle of all hardware support modules. Imports all individual hardware modules below.

#### Individual Hardware Modules

Import these individually for granular control:

- **`nixosModules.hardware-i2c`** - I2C/DDC support for display control
- **`nixosModules.hardware-graphics`** - Graphics drivers (AMD, Intel, NVIDIA)
- **`nixosModules.hardware-fingerprint`** - Fingerprint reader support
- **`nixosModules.hardware-u2f`** - U2F/FIDO security key support
- **`nixosModules.hardware-rtl-sdr`** - RTL-SDR USB device support
- **`nixosModules.hardware-logitech`** - Logitech device support (Solaar)

**Options (all via `mkDefault`, can be overridden):**

- `hardware.i2c.enable` - Enable i2c support
- `hardware.graphics.enable` - Enable graphics drivers
- `hardware.fingerprint.enable` - Enable fingerprint support
- `hardware.u2f.enable` - Enable U2F support
- `hardware.rtl-sdr.enable` - Enable RTL-SDR support
- `hardware.logitech.enable` - Enable Logitech/Solaar support

**Example:**

```nix
{
  # Import all hardware modules
  imports = [ fredsystems.nixosModules.hardware-profiles ];

  # Disable specific features
  hardware.fingerprint.enable = false;
}
```

Or import selectively:

```nix
{
  # Only import what you need
  imports = [
    fredsystems.nixosModules.hardware-graphics
    fredsystems.nixosModules.hardware-u2f
  ];
}
```

### Shared Modules

#### `nixosModules.nas-mounts`

Centralized NAS mount definitions. Provides:

- `nas.mounts.enable` - Enable NAS mounts
- Automatic CIFS mount configuration for common shares

**Example:**

```nix
{
  imports = [ fredsystems.nixosModules.nas-mounts ];

  nas.mounts.enable = true;
}
```

#### `nixosModules.wifi-networks`

Centralized WiFi network profiles. Provides:

- `networking.wireless.networks.enableCommonNetworks` - Enable predefined networks
- Helper function to configure common WiFi networks

**Example:**

```nix
{
  imports = [ fredsystems.nixosModules.wifi-networks ];

  networking.wireless = {
    enable = true;
    networks.enableCommonNetworks = true;
  };
}
```

#### `nixosModules.sync-hosts`

Centralized Syncthing host list. Provides:

- `syncthing.commonHosts` - List of common sync hosts for sync-compose

### Service Modules

#### `nixosModules.github-runners`

Flexible GitHub Actions self-hosted runners with automatic cleanup.

**Options:**

- `ci.githubRunners.enable` - Enable GitHub runners
- `ci.githubRunners.repo` - Repository (e.g., "FredSystems/nixos")
- `ci.githubRunners.defaultTokenFile` - Default token file path
- `ci.githubRunners.runnerCount` - Number of auto-generated runners (default: 0)
- `ci.githubRunners.runners` - Custom runner definitions

**Auto-generated runners example:**

```nix
{
  imports = [ fredsystems.nixosModules.github-runners ];

  ci.githubRunners = {
    enable = true;
    repo = "FredSystems/nixos";
    defaultTokenFile = config.sops.secrets."github-token".path;
    runnerCount = 4;  # Creates runner-1, runner-2, runner-3, runner-4
  };
}
```

**Custom runners example:**

```nix
{
  imports = [ fredsystems.nixosModules.github-runners ];

  ci.githubRunners = {
    enable = true;
    repo = "FredSystems/nixos";
    defaultTokenFile = config.sops.secrets."github-token".path;
    runnerCount = 2;  # Auto-generates runner-1, runner-2

    # Additional custom runner
    runners.special-runner = {
      name = "custom-name";
      url = "https://github.com/OtherOrg/other-repo";
      tokenFile = config.sops.secrets."other-token".path;
      ephemeral = false;
    };
  };
}
```

**Features:**

- Auto-generates numbered runners (runner-1, runner-2, etc.)
- Automatic cleanup of stale runners before registration
- Support for custom runners alongside auto-generated ones
- Ephemeral runners by default
- Per-runner token file and repository override support

#### `nixosModules.default`

Convenience module that imports all common modules. Includes:

- Both profiles (desktop-common, adsb-hub)
- All hardware profiles
- All shared modules
- GitHub runners module

## Available Home Manager Modules

### `homeModules.home-desktop`

Common Home Manager desktop baseline configuration. Provides:

- Shared modules import structure
- Desktop environment configuration helpers

**Example:**

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    fredsystems.url = "github:FredSystems/nixos";
  };

  outputs = { self, nixpkgs, home-manager, fredsystems, ... }: {
    homeConfigurations.myuser = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      modules = [
        fredsystems.homeModules.home-desktop
        ./home.nix
      ];
    };
  };
}
```

### `homeModules.default`

Alias for `homeModules.home-desktop`.

## Best Practices

### Using `lib.mkDefault`

Most profile options use `lib.mkDefault`, making them easy to override:

```nix
{
  imports = [ fredsystems.nixosModules.desktop-common ];

  # This overrides the mkDefault value from the profile
  hardware.fingerprint.enable = false;
}
```

### Selective Hardware Imports

For minimal systems, import only the hardware modules you need:

```nix
{
  imports = [
    fredsystems.nixosModules.hardware-graphics
    # Skip fingerprint, logitech, etc.
  ];
}
```

### Combining Modules

Modules are designed to work together:

```nix
{
  imports = [
    fredsystems.nixosModules.desktop-common
    fredsystems.nixosModules.nas-mounts
    fredsystems.nixosModules.github-runners
  ];

  nas.mounts.enable = true;
  ci.githubRunners = {
    enable = true;
    runnerCount = 2;
    # ...
  };
}
```

## Contributing

If you find issues or want to suggest improvements to these modules, please open an issue or PR at <https://github.com/FredSystems/nixos>.
