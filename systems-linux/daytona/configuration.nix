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

  # Profile-specific settings
  profile.desktop = {
    enableSolaar = true;
    enableU2F = true;
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

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  boot.kernelPackages = pkgs.linuxKernel.packages.linux_testing;

  networking = {
    hostName = "Daytona";
    networkmanager.wifi.scanRandMacAddress = false;
  };

  security.pam.services = {
    login.fprintAuth = false;
    polkit-1.fprintAuth = true;
    polkit-gnome-authentication-agent-1.fprintAuth = true;
    hyprpolkitagent.fprintAuth = true;
  };

  services = {
    udev.packages = with pkgs; [
      solaar
    ];

    logind = {
      settings = {
        Login = {
          HandleLidSwitch = "suspend";
          HandlePowerKey = "suspend";
        };
      };
    };

    fprintd = {
      enable = true;
      tod.enable = true;
      tod.driver = pkgs.libfprint-2-tod1-goodix;
    };
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
