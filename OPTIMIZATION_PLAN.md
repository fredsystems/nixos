# NixOS Configuration Optimization Plan

This document outlines remaining optimization opportunities for the NixOS configuration. These optimizations build upon the initial refactoring that created `shared/` and `profiles/` directories.

## Status: Phase 2 Complete ✅

### Phase 1 (Foundation) - COMPLETED

- ✅ lib.mkDefault additions
- ✅ Hardware profiles

### Phase 2 (Advanced Features) - COMPLETED

- ✅ GitHub runners enhancement
- ✅ nixosModules output

This document now serves as a reference for the completed optimizations.

---

## 1. Extensive Use of `lib.mkDefault` for Overridability

### Current State

- Many profile options are set directly without `lib.mkDefault`
- Overriding profile defaults requires using `lib.mkForce` in individual systems
- Some profiles already use `mkDefault` inconsistently

### Goal

Make all profile configurations easily overridable without requiring `mkForce`.

### Implementation Plan

#### Files to Update

- `profiles/desktop-common.nix`
- `profiles/adsb-hub.nix`
- `profiles/home-desktop.nix`
- `shared/nas-mounts.nix`
- `shared/wifi-networks.nix`

#### Example Changes

**Before:**

```nix
desktop = {
  enable = true;
  enable_extra = true;
};
```

**After:**

```nix
desktop = {
  enable = lib.mkDefault true;
  enable_extra = lib.mkDefault true;
};
```

#### Benefits

- Individual systems can override profile defaults naturally
- Reduces need for `lib.mkForce`
- Makes configuration hierarchy clearer
- Better follows NixOS module best practices

#### Estimated Impact

- ~15-20 files affected
- ~50-80 lines modified
- No reduction in total lines, but improved flexibility

---

## 2. Hardware Profiles Directory

### Hardware Profiles Current State

- Hardware configurations repeated across systems:
  - `hardware.i2c.enable = true` (daytona, maranello)
  - `hardware.graphics` settings (3 systems)
  - Boot kernel parameters
  - Device-specific PAM settings

### mkDefault Goal

Create reusable hardware configuration profiles.

### mkDefault Implementation Plan

#### Directory Structure

```text
nixos/
├── hardware-profiles/
│   ├── default.nix           # Imports all hardware profiles
│   ├── i2c.nix               # I2C device support
│   ├── graphics.nix          # GPU acceleration
│   ├── fingerprint.nix       # Fingerprint reader support
│   ├── u2f.nix               # U2F/FIDO2 authentication
│   ├── rtl-sdr.nix           # RTL-SDR USB device support
│   └── logitech.nix          # Logitech device support (Solaar)
```

#### Profile Examples

**`hardware-profiles/i2c.nix`**

```nix
{ config, lib, user, ... }:
{
  options.hardware-profile.i2c.enable = lib.mkEnableOption "I2C device support";

  config = lib.mkIf config.hardware-profile.i2c.enable {
    hardware.i2c.enable = true;
    users.users.${user}.extraGroups = [ "i2c" ];
  };
}
```

**`hardware-profiles/graphics.nix`**

```nix
{ config, lib, ... }:
{
  options.hardware-profile.graphics = {
    enable = lib.mkEnableOption "graphics acceleration";
    enable32Bit = lib.mkEnableOption "32-bit graphics support";
  };

  config = lib.mkIf config.hardware-profile.graphics.enable {
    hardware.graphics = {
      enable = true;
      enable32Bit = lib.mkDefault config.hardware-profile.graphics.enable32Bit;
    };
  };
}
```

**`hardware-profiles/fingerprint.nix`**

```nix
{ config, lib, pkgs, ... }:
{
  options.hardware-profile.fingerprint = {
    enable = lib.mkEnableOption "fingerprint reader";
    driver = lib.mkOption {
      type = lib.types.package;
      default = pkgs.libfprint-2-tod1-goodix;
      description = "Fingerprint driver package";
    };
  };

  config = lib.mkIf config.hardware-profile.fingerprint.enable {
    services.fprintd = {
      enable = true;
      tod.enable = true;
      tod.driver = config.hardware-profile.fingerprint.driver;
    };

    security.pam.services = {
      polkit-1.fprintAuth = lib.mkDefault true;
      polkit-gnome-authentication-agent-1.fprintAuth = lib.mkDefault true;
      hyprpolkitagent.fprintAuth = lib.mkDefault true;
    };
  };
}
```

#### Integration with Existing Profiles

Update `profiles/desktop-common.nix`:

```nix
{
  imports = [
    ../hardware-profiles
  ];

  config = {
    hardware-profile.i2c.enable = lib.mkDefault true;
    # Solaar moved to hardware-profiles/logitech.nix
  };
}
```

#### Systems Using Hardware Profiles

| Profile     | Used By                     |
| ----------- | --------------------------- |
| i2c         | daytona, maranello          |
| graphics    | daytona, maranello          |
| fingerprint | daytona                     |
| u2f         | daytona, maranello          |
| rtl-sdr     | All ADSB hubs, user default |
| logitech    | daytona, maranello          |

#### Systems Benefits

- Centralized hardware support configuration
- Easy to enable/disable hardware features
- Reusable across different system types
- Clear documentation of hardware requirements

#### Systems Estimated Impact

- 6 new files created
- ~8 files modified
- ~100 lines added, ~80 lines removed
- Net: +20 lines but better organization

---

## 3. GitHub Runners Module Extraction

### GitHub Runners Current State

- GitHub runner configuration duplicated in:
  - `modules/github-runners.nix` (custom module)
  - `fredhub/configuration.nix` (4 runners)
  - `hfdlhub1/configuration.nix` (commented out)
  - `hfdlhub2/configuration.nix` (commented out)
  - `vdlmhub/configuration.nix` (commented out)

### GitHub Goal

Create a flexible, reusable GitHub runners module with presets.

### GitHubImplementation Plan

#### Enhanced Module Structure

**`modules/github-runners.nix`** (enhanced):

```nix
{ config, lib, ... }:
{
  options.ci.githubRunners = {
    enable = lib.mkEnableOption "GitHub Actions runners";

    repo = lib.mkOption {
      type = lib.types.str;
      default = "FredSystems/nixos";
      description = "GitHub repository URL";
    };

    defaultTokenFile = lib.mkOption {
      type = lib.types.path;
      description = "Default token file for all runners";
    };

    runnerCount = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = "Number of runners to create (creates runner-1, runner-2, etc.)";
    };

    runners = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          url = lib.mkOption { type = lib.types.str; };
          tokenFile = lib.mkOption { type = lib.types.path; };
          ephemeral = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
        };
      });
      default = {};
      description = "Individual runner configurations";
    };
  };

  config = lib.mkIf config.ci.githubRunners.enable {
    # Auto-generate runners based on count
    services.github-runners = lib.mkMerge [
      # Auto-generated runners
      (lib.listToAttrs (lib.genList (i: {
        name = "runner-${toString (i + 1)}";
        value = {
          enable = true;
          url = config.ci.githubRunners.repo;
          name = "${config.networking.hostName}-runner-${toString (i + 1)}";
          tokenFile = config.ci.githubRunners.defaultTokenFile;
          ephemeral = true;
        };
      }) config.ci.githubRunners.runnerCount))

      # Custom runners
      config.ci.githubRunners.runners
    ];
  };
}
```

#### Usage Examples

**Simple (fredhub-style):**

```nix
{
  ci.githubRunners = {
    enable = true;
    runnerCount = 4;  # Creates runner-1 through runner-4
    defaultTokenFile = config.sops.secrets."github-token".path;
  };
}
```

**Custom (mixed approach):**

```nix
{
  ci.githubRunners = {
    enable = true;
    runnerCount = 2;  # Creates runner-1 and runner-2
    defaultTokenFile = config.sops.secrets."github-token".path;

    # Additional custom runner
    runners.special-runner = {
      url = "https://github.com/OtherOrg/other-repo";
      tokenFile = config.sops.secrets."other-token".path;
      ephemeral = false;
    };
  };
}
```

**Disabled (current commented-out systems):**

```nix
{
  # Simply don't set enable, or set to false
  ci.githubRunners.enable = false;
}
```

#### GitHub Benefits

- No duplication of runner configuration
- Easy to scale runner count up/down
- Consistent naming convention
- Can mix auto-generated and custom runners
- Clear enable/disable mechanism

#### GitHub Estimated Impact

- 1 file enhanced (`modules/github-runners.nix`)
- ~5 files simplified
- ~150 lines added to module
- ~200 lines removed from systems
- Net: -50 lines

---

## 4. Flake `nixosModules` Output

### Flake Current State

- Profiles and shared configs only accessible within this flake
- Cannot be easily reused in other flakes
- No standard way to import these configurations externally

### Flake Goal

Export reusable modules via flake outputs for use in other projects.

### Flake Implementation Plan

#### Flake Structure Enhancement

**`flake.nix`** additions:

```nix
{
  outputs = { self, nixpkgs, ... }: {
    # Existing outputs...

    # New: Reusable modules
    nixosModules = {
      # Profile modules
      desktop-common = import ./profiles/desktop-common.nix;
      adsb-hub = import ./profiles/adsb-hub.nix;

      # Hardware modules
      hardware-i2c = import ./hardware-profiles/i2c.nix;
      hardware-graphics = import ./hardware-profiles/graphics.nix;
      hardware-fingerprint = import ./hardware-profiles/fingerprint.nix;
      hardware-u2f = import ./hardware-profiles/u2f.nix;
      hardware-rtl-sdr = import ./hardware-profiles/rtl-sdr.nix;
      hardware-logitech = import ./hardware-profiles/logitech.nix;

      # Shared configurations
      nas-mounts = import ./shared/nas-mounts.nix;
      wifi-networks = import ./shared/wifi-networks.nix;
      sync-hosts = import ./shared/sync-hosts.nix;

      # Service modules
      github-runners = import ./modules/github-runners.nix;
      monitoring-agent = import ./modules/monitoring/agent;

      # Convenience: all modules
      default = {
        imports = [
          ./profiles/desktop-common.nix
          ./profiles/adsb-hub.nix
          ./hardware-profiles
          ./shared/nas-mounts.nix
          ./shared/wifi-networks.nix
          ./shared/sync-hosts.nix
          ./modules/github-runners.nix
        ];
      };
    };

    # New: Home Manager modules
    homeModules = {
      desktop-common = import ./profiles/home-desktop.nix;
      xdg-mime-common = import ./packages/desktop/environments/modules/xdg-mime-common.nix;

      default = {
        imports = [
          ./profiles/home-desktop.nix
          ./packages/desktop/environments/modules/xdg-mime-common.nix
        ];
      };
    };
  };
}
```

#### External Usage Example

Other flakes can now import these modules:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    fred-nixos.url = "github:FredSystems/nixos";
  };

  outputs = { nixpkgs, fred-nixos, ... }: {
    nixosConfigurations.my-system = nixpkgs.lib.nixosSystem {
      modules = [
        # Use Fred's desktop profile
        fred-nixos.nixosModules.desktop-common

        # Or specific hardware profiles
        fred-nixos.nixosModules.hardware-i2c
        fred-nixos.nixosModules.hardware-graphics

        # System-specific config
        {
          profile.desktop = {
            enableSolaar = true;
            enableU2F = true;
          };
        }
      ];
    };
  };
}
```

#### Documentation Structure

Create `modules/README.md`:

```markdown
# FredSystems NixOS Modules

## Available Modules

### System Profiles

- `desktop-common` - Common desktop configuration
- `adsb-hub` - ADSB monitoring hub configuration

### Hardware Profiles

- `hardware-i2c` - I2C device support
- `hardware-graphics` - GPU acceleration
- `hardware-fingerprint` - Fingerprint reader
- `hardware-u2f` - U2F/FIDO2 authentication
- `hardware-rtl-sdr` - RTL-SDR USB devices
- `hardware-logitech` - Logitech device support

### Shared Configurations

- `nas-mounts` - Standard NAS mount definitions
- `wifi-networks` - Standard WiFi profiles
- `sync-hosts` - Sync-compose host list

### Services

- `github-runners` - GitHub Actions self-hosted runners
- `monitoring-agent` - Prometheus monitoring agent

## Usage

See individual module files for options and configuration examples.
```

#### Flake Benefits

- Modules can be reused in other projects
- Easier testing in isolation
- Clearer module boundaries
- Standard flake interface
- Better documentation surface
- Potential for community contribution

#### Flake Estimated Impact

- 1 file modified (`flake.nix`)
- 1 documentation file created
- ~80 lines added
- No deletions
- Enables external reuse

---

## Implementation Priority

### Phase 1: Foundation (Recommended First)

1. **lib.mkDefault additions** - Low risk, high benefit
2. **Hardware profiles** - Moderate effort, good organization improvement

### Phase 2: Advanced Features (After Phase 1) - ✅ COMPLETED

1. **GitHub runners enhancement** - ✅ COMPLETED
   - Added `runnerCount` option for auto-generating numbered runners
   - Simplified fredhub configuration from 20+ lines to 3 lines
   - Maintains support for custom runners alongside auto-generated ones
2. **nixosModules output** - ✅ COMPLETED
   - Exported 14+ reusable nixosModules
   - Exported 2 homeModules
   - Created comprehensive MODULES.md documentation
   - Updated main README with usage examples

---

## Testing Strategy

For each optimization:

1. **Before implementation:**
   - Document current behavior
   - `nix flake check` must pass
   - Test build specific systems

2. **During implementation:**
   - Implement one profile/module at a time
   - Test after each change
   - Verify overrides work as expected

3. **After implementation:**
   - Full `nix flake check`
   - Build and test affected systems
   - Verify override behavior with test cases
   - Update documentation

---

## Rollback Plan

Each optimization should be:

- Committed separately
- Fully reversible via git
- Documented with before/after examples

If issues arise:

1. Identify failing system
2. Check configuration diff
3. Revert specific commit if needed
4. Document issue for future reference

---

## Success Metrics

- **Reduced duplication:** Track lines saved per optimization
- **Improved flexibility:** Count systems that can override defaults
- **Better organization:** Measure files per logical grouping
- **External reusability:** Track potential external users of modules
- **Maintainability:** Time to add new system configuration

---

## Notes

- All optimizations should maintain backward compatibility where possible
- Keep existing system configs working during migration
- Document breaking changes clearly
- Consider creating a migration guide for each phase

---

**Last Updated:** 2025-01-XX
**Status:** Phase 2 Complete - All Major Optimizations Implemented
