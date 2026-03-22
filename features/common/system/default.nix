{
  config,
  pkgs,
  inputs,
  ...
}:
{
  config = {

    # Enable networking
    networking.networkmanager.enable = true;

    environment.systemPackages = with pkgs; [
      pass
      wget
      unzip
      file
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
