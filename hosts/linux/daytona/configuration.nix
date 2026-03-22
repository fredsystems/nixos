{
  pkgs,
  user,
  stateVersion,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
    ../../../profiles/desktop.nix
  ];

  # Hardware profile settings
  hardware-profile = {
    graphics.enable = true;
    graphics.enable32Bit = true;
    fingerprint.enable = true;
    logitech.enable = true;
  };

  profile.desktop.bluetooth.enable = true;

  # extra options
  ai = {
    enable = false;
    opencode.enable = true;
    local-llm = {
      enable = false;
      ollamaPackage = pkgs.ollama;
    };
  };

  desktop.enable_games = false;

  boot.kernelPackages = pkgs.linuxPackages_latest;

  networking = {
    hostName = "Daytona";
    networkmanager.wifi.scanRandMacAddress = false;
  };

  system.activationScripts.sddm-hyprland-config = ''
    mkdir -p /var/lib/sddm/.config/hypr
    cat <<EOF > /var/lib/sddm/.config/hypr/hyprland.conf
    EOF
    chown -R sddm:sddm /var/lib/sddm/.config
  '';

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

    logind = {
      settings = {
        Login = {
          HandleLidSwitch = "suspend";
          HandlePowerKey = "suspend";
        };
      };
    };
  };

  security.pam.services = {
    login.fprintAuth = false;
  };

  powerManagement.enable = false;

  environment.systemPackages = [ ];

  system.stateVersion = stateVersion;

  sops.secrets = {
    "fred-yubi" = {
      path = "/home/${user}/.config/Yubico/u2f_keys";
      owner = user;
      mode = "0600";
    };
  };
}
