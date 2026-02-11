{
  pkgs,
  user,
  stateVersion,
  lib,
  ...
}:
let
  monitors = import ./monitors.nix;
  hyprMonitors = import ../../modules/monitors/hyprland.nix {
    inherit lib monitors;
  };
in
{
  imports = [
    ./hardware-configuration.nix
    ../../profiles/desktop-common.nix
  ];

  # Profile-specific settings
  profile.desktop = {
    enableSolaar = true;
    enableU2F = true;
  };

  # extra options
  ai.enable = true;
  desktop = {
    enable_games = true;
    enable_streaming = true;
  };
  hardware.graphics.enable = true;

  boot = {
    kernelPackages = pkgs.linuxKernel.packages.linux_6_18;

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
    udev = {
      packages = with pkgs; [
        solaar
      ];

      extraRules = ''
        ACTION=="add", SUBSYSTEM=="usb", TEST=="power/control", ATTR{power/control}="on"
      '';
    };

    displayManager.sddm = {
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
