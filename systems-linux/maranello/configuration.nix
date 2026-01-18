{
  config,
  pkgs,
  user,
  stateVersion,
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
  ai.enable = true;
  desktop = {
    enable = true;
    enable_extra = true;
    enable_games = true;
    enable_streaming = true;
  };
  deployment.role = "desktop";
  sops_secrets.enable_secrets.enable = true;
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

  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", TEST=="power/control", ATTR{power/control}="on"
  '';

  networking.hostName = "maranello";

  hardware.i2c.enable = true;
  users.users.${user}.extraGroups = [ "i2c" ];

  environment.systemPackages = with pkgs; [ ];

  system.stateVersion = stateVersion;

  systemd.tmpfiles.rules = [
    "d /var/lib/gdm/.config 0755 gdm gdm -"
    "f /var/lib/gdm/.config/monitors.xml 0644 gdm gdm - ${./monitors.xml}"
  ];

  security.pam.services = {
    polkit-1.u2fAuth = true;
    polkit-gnome-authentication-agent-1.u2fAuth = true;
    hyprpolkitagent.u2fAuth = true;
  };

  services.displayManager.sddm = {
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

  system.activationScripts.sddm-hyprland-config = ''
    mkdir -p /var/lib/sddm/.config/hypr
    cat <<EOF > /var/lib/sddm/.config/hypr/hyprland.conf
    # monitor=name,res,offset,scale

    # HDMI-A-1 at top left
    monitor=HDMI-A-1, 2560x1440@144.01, 0x0, 1

    # DP-2 below HDMI-A-1
    monitor=DP-2, 2560x1440@143.97, 0x1440, 1

    # DP-1 (Primary) to the right of DP-2
    monitor=DP-3, 2560x1440@143.97, 2560x1440, 1

    # DP-1 at top right
    monitor=DP-1, highrr, 0x-1440, 1

    ecosystem {
      no_update_news = true
      no_donation_nag = true
    }

    EOF
    chown -R sddm:sddm /var/lib/sddm/.config
  '';

  sops.secrets = {
    # wifi
    "wifi.env" = { };

    "fred-yubi-maranello" = {
      path = "/home/${user}/.config/Yubico/u2f_keys";
      owner = user;
      mode = "0600";
    };

    "email/natca/signature" = {
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

    "email/icloud/signature" = {
      owner = user;
      mode = "0600";
    };
  };

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
