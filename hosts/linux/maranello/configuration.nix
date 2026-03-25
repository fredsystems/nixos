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
      "qwen3-coder:latest"
      "qwen2.5-coder:7b"
      "qwen2.5-coder:32b"
      "deepseek-coder-v2:latest"
      "qwen3.5:9b"
    ];
  };

  desktop = {
    enable_games = true;
    enable_streaming = true;
  };

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
    cat <<EOF > /var/lib/sddm/.config/hypr/hyprland.conf
    ${lib.concatStringsSep "\n" (map (m: "monitor=${m}") hyprMonitors)}
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
