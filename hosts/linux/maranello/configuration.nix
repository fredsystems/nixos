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

    # This desk has a second machine on it -- the Mac Studio, driving its own
    # monitor -- which until now meant a second keyboard and mouse taking up
    # space next to the first. maranello keeps the physical peripherals and
    # hands them over when the pointer leaves the right-hand edge.
    #
    # No `authorizedFingerprints` here, deliberately. Authorisation is checked
    # by the LISTENING side only (src/listen.rs verifies the peer certificate
    # against that list); the connecting side runs with
    # `insecure_skip_verify: true` (src/connect.rs). maranello only ever
    # initiates, so it has nothing to authorise -- the Mac Studio carries
    # maranello's fingerprint instead. Add the Mac's fingerprint here if this
    # ever becomes bidirectional.
    lan-mouse = {
      enable = true;
      clients = [
        {
          # Bonjour name. nix-darwin's networking.localHostName defaults to
          # networking.hostName, which flake/lib/mk-darwin-system.nix sets
          # from the directory name, so this tracks hosts/darwin/.
          hostname = "Freds-Mac-Studio.local";

          # Required, not an optimisation -- the hostname above does NOT
          # resolve on its own. lan-mouse builds its own hickory-resolver
          # (src/dns.rs) and calls lookup_ip directly, which never consults
          # NSS, so avahi/nssmdns4 is bypassed and `.local` is treated as an
          # ordinary DNS name: the observed failure is a query for
          # "freds-mac-studio.local.localdomain" against the LAN nameserver.
          # `avahi-resolve` and `getent ahosts` both answer 192.168.31.103
          # for this name; lan-mouse simply is not asking them.
          #
          # This wants a DHCP reservation on the router to stay true.
          ips = [ "192.168.31.103" ];

          # The Mac's monitor sits to the right of the 2x2 grid of 27" panels
          # described in ./monitors.nix. Note that the barrier spans the right
          # edge of the WHOLE layout, i.e. both DP-1 (top-right) and DP-2
          # (bottom-right) -- 2880px of it -- not just the panel the Mac is
          # level with.
          position = "right";
        }
      ];
    };
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
