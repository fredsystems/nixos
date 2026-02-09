{
  config,
  pkgs,
  stateVersion,
  user,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/secrets/sops.nix
    ../../modules/nas-system.nix
  ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # extra options
  ai = {
    enable = true;
    local-llm = {
      enable = true;
      ollamaPackage = pkgs.ollama;
    };
  };
  desktop = {
    enable = true;
    enable_extra = true;
    enable_games = false;
    enable_streaming = false;
  };

  deployment.role = "desktop";

  sops_secrets.enable_secrets.enable = true;

  hardware.i2c.enable = true;
  users.users.${user}.extraGroups = [ "i2c" ];

  services.solaar = {
    enable = true; # Enable the service
    package = pkgs.solaar; # The package to use
    window = "hide"; # Show the window on startup (show, *hide*, only [window only])
    batteryIcons = "regular"; # Which battery icons to use (*regular*, symbolic, solaar)
    extraArgs = ""; # Extra arguments to pass to solaar on startup
  };

  services.udev.packages = with pkgs; [
    solaar
  ];

  nas = {
    enable = true;

    mounts = [
      {
        path = "/mnt/nas/fred";
        host = "192.168.31.16";
        share = "/volume1/Fred Share";
        type = "nfs";
        gvfsName = "Fred Share";
      }

      {
        path = "/mnt/nas/discord";
        host = "192.168.31.16";
        share = "/volume1/discord";
        type = "nfs";
        gvfsName = "Discord";
      }

      {
        path = "/mnt/nas/dropbox";
        host = "192.168.31.16";
        share = "/volume1/Dropbox";
        type = "nfs";
        gvfsName = "Dropbox";
      }

      {
        path = "/mnt/nas/media";
        host = "192.168.31.16";
        share = "/volume1/Media";
        type = "nfs";
        gvfsName = "Media";
      }

      {
        path = "/mnt/nas/prometheus";
        host = "192.168.31.16";
        share = "/volume1/Prometheus";
        type = "nfs";
        gvfsName = "Prometheus";
      }
    ];
  };

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

    polkit-1.u2fAuth = true;
    polkit-gnome-authentication-agent-1.u2fAuth = true;
    hyprpolkitagent.u2fAuth = true;
  };

  services = {
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
    # wifi
    "wifi.env" = { };

    "fred-yubi" = {
      path = "/home/${user}/.config/Yubico/u2f_keys";
      owner = user;
      mode = "0600";
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

  networking.networkmanager = {
    enable = true;

    ensureProfiles = {
      environmentFiles = [
        config.sops.secrets."wifi.env".path
      ];

      profiles = {
        "Home" = {
          connection.id = "Home";
          connection.type = "wifi";

          wifi.ssid = "$home_ssid";

          wifi-security = {
            key-mgmt = "wpa-psk";
            psk = "$home_psk";
          };
        };

        "Work" = {
          connection.id = "Work";
          connection.type = "wifi";

          wifi.ssid = "$work_ssid";

          wifi-security = {
          };
        };

        "Parents" = {
          connection.id = "Parents";
          connection.type = "wifi";

          wifi.ssid = "$parents_ssid";

          wifi-security = {
            key-mgmt = "wpa-psk";
            psk = "$parents_psk";
          };
        };
      };
    };
  };
}
