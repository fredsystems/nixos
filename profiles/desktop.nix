{
  config,
  lib,
  pkgs,
  user,
  ...
}:

{
  imports = [
    ../modules/hardware
    ../modules/services/nas-system.nix
    ../modules/secrets/sops.nix
    ../modules/data/nas-mounts.nix
    ../modules/data/wifi-networks.nix
    # Monitoring: node_exporter only. cadvisor (Docker container metrics) is
    # deliberately not pulled in -- desktops don't run the same container
    # fleet.
    #
    # Log shipping is NOT excluded on purpose, it is just per-host: the two
    # desktops need different shippers. Daytona is a roaming laptop on
    # push-based monitoring with its own inline alloy config that also does
    # prometheus remote_write; maranello is stationary, is scraped normally,
    # and imports modules/monitoring/agent/alloy.nix for the journal half
    # only. Defining alloy here would collide with Daytona's.
    ../modules/monitoring/agent/node_exporter.nix
  ];

  options.profile.desktop = {
    bluetooth.enable = lib.mkEnableOption "Bluetooth + Blueman + Solaar stack";
  };

  config = lib.mkMerge [
    # Always enable for desktop profile
    {
      desktop = {
        enable = lib.mkDefault true;
        enable_extra = lib.mkDefault true;
      };

      nas = {
        enable = lib.mkDefault true;
        mounts = lib.mkDefault config.shared.nasMounts.standard;
      };

      shared.enableStandardWifi = lib.mkDefault true;

      # Enable hardware profiles for desktop systems
      hardware-profile.i2c.enable = lib.mkDefault true;
      hardware-profile.u2f.enable = lib.mkDefault true;

      # Standard email secrets for desktops
      sops.secrets = {
        "wifi.env" = { };

        # Attic push credential. Only the two desktops push by hand; every
        # server and both Macs pull anonymously and get no token at all.
        #
        # Owned by the user because it is read by a Home Manager activation
        # script running as them, which renders ~/.config/attic/config.toml
        # from it. See modules/services/attic/attic_client.nix for why the
        # token cannot simply be a `home.file` entry, and
        # agent-docs/ATTIC_OPERATIONS.md for how it is minted and rotated.
        "attic/desktop_token" = {
          owner = user;
          mode = "0400";
        };
        "email/natca/signature" = {
          owner = user;
          mode = "0600";
        };
        "email/icloud/signature" = {
          owner = user;
          mode = "0600";
        };
        "email/icloud/caldav_server" = {
          owner = user;
          mode = "0600";
        };
        "email/icloud/address" = {
          owner = user;
          mode = "0600";
        };
        "email/icloud/password" = {
          owner = user;
          mode = "0600";
        };
      };

      deployment.role = lib.mkDefault "desktop";
      sops_secrets.enable_secrets.enable = lib.mkDefault true;
    }

    # ── Bluetooth / Blueman / Solaar ─────────────────────────────────────────
    (lib.mkIf config.profile.desktop.bluetooth.enable {
      hardware.bluetooth.enable = true;

      # Solaar is configured through the native nixpkgs module
      # (nixos/modules/programs/solaar.nix), contributed upstream by the same
      # maintainer as the former Svenum/Solaar-Flake input. That input was
      # dropped because its module declared `programs.solaar.enable` as a
      # renamed alias of `services.solaar.enable`, which collides with the
      # nixpkgs declaration of the same option and makes evaluation throw.
      #
      # `userService.enable` is required: nixpkgs gates the systemd user
      # service behind it, whereas the old module created that unit
      # unconditionally. Leaving it off would silently stop Solaar from
      # starting with the graphical session.
      #
      # `window`, `batteryIcons` and `extraArgs` are omitted because the
      # nixpkgs defaults ("hide", "regular", none) already match what this
      # profile set explicitly before the move.
      programs.solaar = {
        enable = true;
        userService.enable = true;
      };

      services = {
        blueman.enable = true;

        power-profiles-daemon.enable = true;

        udev.packages = [ pkgs.solaar ];
      };
    })
  ];
}
