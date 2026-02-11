{
  pkgs,
  user,
  stateVersion,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
    ../../profiles/desktop-common.nix
  ];

  # Hardware profile settings
  hardware-profile = {
    graphics.enable = true;
    graphics.enable32Bit = true;
    fingerprint.enable = true;
    logitech.enable = true;
  };

  # extra options
  ai = {
    enable = true;
    local-llm = {
      enable = true;
      ollamaPackage = pkgs.ollama;
    };
  };

  desktop.enable_games = false;

  boot.kernelPackages = pkgs.linuxKernel.packages.linux_testing;

  networking = {
    hostName = "Daytona";
    networkmanager.wifi.scanRandMacAddress = false;
  };

  services = {
    # Solaar configuration (requires solaar module from flake)
    solaar = {
      enable = true;
      package = pkgs.solaar;
      window = "hide";
      batteryIcons = "regular";
      extraArgs = "";
    };

    udev.packages = with pkgs; [ solaar ];

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

  powerManagement.enable = true;

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
