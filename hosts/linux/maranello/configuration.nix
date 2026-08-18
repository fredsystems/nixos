{
  pkgs,
  user,
  stateVersion,
  lib,
  ...
}:
let
  monitors = import ./monitors.nix;
  hyprMonitors = import ../../../modules/compositors/hyprland.nix {
    inherit lib monitors;
  };
in
{
  imports = [
    ./hardware-configuration.nix
    ../../../profiles/desktop.nix

    # Log shipping to Loki. Imported per-host rather than from the desktop
    # profile because the two desktops need different shippers: Daytona is a
    # roaming laptop converted to push-based monitoring (f8081793), so it
    # carries its own inline alloy config that ALSO does prometheus
    # remote_write, and pulling this module in there would define
    # services.alloy twice. maranello is stationary and is scraped normally at
    # maranello.local:9100, so it needs only the journal half -- which is all
    # this module is, by design ("deliberately a dumb shipper").
    #
    # Without this, maranello was the only host in the fleet whose logs existed
    # nowhere but its own journal, and that journal is size-bound: measured at
    # 8 days of retention against a 30-day policy, because SystemMaxUse=1G
    # binds long before MaxRetentionSec=30day.
    ../../../modules/monitoring/agent/alloy.nix
  ];

  # Hardware profile settings
  hardware-profile = {
    graphics.enable = true;
    logitech.enable = true;
  };

  profile.desktop.bluetooth.enable = true;

  # extra options
  ai = {
    enable = true;

    local-llm.models = [
      "qwen3.6:latest"
      "gemma4:latest"
    ];
  };

  desktop = {
    enable_games = true;
    enable_streaming = true;
  };

  virtualization.libvirt.enable = true;

  boot = {
    kernelPackages = pkgs.linuxPackages_latest;

    kernelParams = [
      "usbcore.autosuspend=-1"
      "xhci_hcd.quirks=270336"
    ];

    initrd.kernelModules = [
      "usbhid"
      "hid_generic"
      "hid_logitech_hidpp"
      "hid_logitech_dj"
      "hid_apple" # optional but helpful for Keychron
    ];
  };

  system.stateVersion = stateVersion;

  services = {
    displayManager = {
      defaultSession = "hyprland";
      sddm = {
        enable = true;
        wayland = {
          enable = true;
        };

        settings = {
          Wayland = {
            EnableHiDPI = true;

            CompositorCommand = "${pkgs.hyprland}/bin/start-hyprland";
          };
        };
      };
    };
  };

  system.activationScripts.sddm-hyprland-config = ''
    mkdir -p /var/lib/sddm/.config/hypr
    # hyprland.conf (hyprlang) is deprecated upstream; drop any stale copy left
    # behind by a pre-Lua generation so Hyprland does not read it.
    rm -f /var/lib/sddm/.config/hypr/hyprland.conf
    cat <<EOF > /var/lib/sddm/.config/hypr/hyprland.lua
    -- Auto-generated for the SDDM Wayland session.
    ${lib.concatStringsSep "\n    " hyprMonitors}
    EOF
    chown -R sddm:sddm /var/lib/sddm/.config
  '';

  sops.secrets = {
    "fred-yubi-maranello" = {
      path = "/home/${user}/.config/Yubico/u2f_keys";
      owner = user;
      mode = "0600";
    };
  };

  networking = {
    firewall.allowedTCPPorts = [ 3000 ];
    hostName = "maranello";
  };
}
