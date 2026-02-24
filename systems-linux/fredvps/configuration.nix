{
  pkgs,
  lib,
  stateVersion,
  config,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
    ../../profiles/adsb-hub.nix
    ./nginx.nix
  ];

  # Not on the LAN - exclude from the monitoring agent mesh until Tailscale is set up.
  deployment.role = "standalone";

  # The local Attic cache (192.168.31.14) is unreachable from the VPS — use
  # only the public cache until Tailscale is set up.
  nix.settings.substituters = lib.mkForce [ "https://cache.nixos.org" ];

  # The common packages module unconditionally enables systemd-boot and
  # networkmanager; override both since this VPS uses GRUB + systemd-networkd.
  boot = {
    # Boot - GRUB on /dev/sda (VPS, BIOS boot, no EFI)
    loader = {
      systemd-boot.enable = lib.mkForce false;
      efi.canTouchEfiVariables = lib.mkForce false;
      grub = {
        enable = true;
        device = "/dev/sda";
        useOSProber = false;
      };
    };

    # Use latest kernel
    kernelPackages = pkgs.linuxPackages_latest;
  };

  # Secondary user — mirrors the groups and packages that users/user/default.nix
  # gives fred, but declared locally since mkSystem only wires up one system user.
  users.users.nik = {
    linger = true;
    isNormalUser = true;
    description = "Nik";
    extraGroups = [
      "networkmanager"
      "wheel"
      "docker"
      "wireshark"
    ];
    packages = with pkgs; [
      gh
      stow
      rtl-sdr-librtlsdr
      rrdtool
    ];
  };

  system.stateVersion = stateVersion;

  networking = {
    hostName = "fredvps";
    useNetworkd = true;
    useDHCP = false;
    networkmanager.enable = lib.mkForce false;
  };

  systemd.network = {
    enable = true;
    networks."10-wan" = {
      matchConfig.Name = "enp1s0";
      networkConfig = {
        DHCP = "ipv4";
        IPv6AcceptRA = false;
      };
      address = [
        "2a01:4ff:f0:2bab::/64"
      ];
      routes = [
        { routeConfig.Gateway = "fe80::1"; }
      ];
    };
  };

  system.activationScripts.adsbDockerCompose = {
    text = ''
      # Ensure directory exists (does not touch contents if already there)
      install -d -m0755 -o fred -g users /opt/adsb
    '';
    deps = [ ];
  };

  sops.secrets = {
    "docker/fredvps/tar1090.env" = {
      format = "yaml";
    };

    "docker/fredvps/acars_router.env" = {
      format = "yaml";
    };

    "docker/fredvps/acarshub.env" = {
      format = "yaml";
    };
  };

  services = {
    adsb.containers = [
      ###############################################################
      # DOZZLE AGENT
      ###############################################################
      {
        name = "dozzle-agent";
        image = "amir20/dozzle:v10.0.4";
        exec = "agent";

        volumes = [
          "/var/run/docker.sock:/var/run/docker.sock:ro"
        ];

        ports = [ "7007:7007" ];
      }

      ###############################################################
      # IMAGE API
      ###############################################################
      {
        name = "imageapi";
        image = "ghcr.io/sdr-enthusiasts/sdre-image-api:latest-build-5";

        volumes = [
          "/opt/adsb/imageapi/data:/opt/api"
        ];

        ports = [ "3001:3000" ];
      }

      ###############################################################
      # tar1090
      ###############################################################
      {
        name = "tar1090";
        image = "ghcr.io/sdr-enthusiasts/docker-tar1090:latest-build-1414";

        environmentFiles = [
          config.sops.secrets."docker/fredvps/tar1090.env".path
        ];

        volumes = [
          "/opt/adsb/tar1090/heatmap:/var/globe_history"
          "/opt/adsb/tar1090/timelapse:/var/timelapse1090"
          "/opt/adsb/tar1090/graphs_1090:/var/lib/collectd"
          "/proc/diskstats:/proc/diskstats:ro"
        ];

        ports = [
          "8081:80"
          "30002:30002"
          "30003:30003"
          "30004:30004"
          "30047:30047"
          "30005:30005"
          "12000:12000"
        ];
      }

      ###############################################################
      # acars_router
      ###############################################################
      {
        name = "acars_router";
        image = "ghcr.io/sdr-enthusiasts/acars_router:latest-build-565";

        environmentFiles = [
          config.sops.secrets."docker/fredvps/acars_router.env".path
        ];

        ports = [
          "5556:5556"
          "5555:5555"
          "5550:5550"
          "15550:15550"
          "15555:15555"
          "15556:15556"
          "35556:35556"
        ];
      }

      ###############################################################
      # ACARS Hub
      ###############################################################
      {
        name = "acarshub";
        image = "ghcr.io/sdr-enthusiasts/docker-acarshub:v4-latest-build-46";

        environmentFiles = [
          config.sops.secrets."docker/fredvps/acarshub.env".path
        ];

        volumes = [
          "/opt/adsb/acarshub:/run/acars"
        ];

        ports = [
          "8085:80"
          "8888:8888"
        ];
      }
    ];
  };
}
