{
  config,
  pkgs,
  inputs,
  ...
}:
{
  config = {

    # Bootloader.
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    # Enable networking
    networking.networkmanager.enable = true;

    environment.systemPackages = with pkgs; [
      pass
      wget
      unzip
      file
      lsd
      zip
      toybox
      nix-index
      lm_sensors
      dig
      nethogs
      inotify-tools
      usbutils
      hwdata
      airspy
      pciutils
      inputs.nixos-needsreboot.packages.${config.nixpkgs.hostPlatform.system}.default
    ];

    services = {
      avahi = {
        enable = true;
        nssmdns4 = true;
        publish = {
          enable = true;
          addresses = true;
          workstation = true;
        };
      };
      fwupd.enable = true;

      udev.packages = with pkgs; [
        airspy
      ];

      logind = {
        settings = {
          Login = {
            KillUserProcesses = true;
          };
        };
      };
    };

    xdg.portal = {
      enable = true;
      config.common.default = "*";
      extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    };

    nixpkgs.config = {
      permittedInsecurePackages = [
        "openssl-1.1.1w"
      ];

      allowUnfree = true;
    };

    security.polkit.enable = true;
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (
          subject.isInGroup("users")
            && (
              action.id == "org.freedesktop.login1.reboot" ||
              action.id == "org.freedesktop.login1.reboot-multiple-sessions" ||
              action.id == "org.freedesktop.login1.power-off" ||
              action.id == "org.freedesktop.login1.power-off-multiple-sessions"
            )
          )
        {
          return polkit.Result.YES;
        }
      })
    '';
  };
}
