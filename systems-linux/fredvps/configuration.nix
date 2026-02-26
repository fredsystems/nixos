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
    ../../modules/tailscale
    ./nginx.nix
  ];

  # Tailscale MagicDNS name — fill in your tailnet name, e.g. "fredvps.tail1234.ts.net"
  # Run `tailscale status` after first deploy to confirm the assigned name.
  deployment.scrapeAddress = "fredvps.tailc21fc7.ts.net";

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

  system.stateVersion = stateVersion;

  networking = {
    hostName = "fredvps";
    useNetworkd = true;
    useDHCP = false;
    networkmanager.enable = lib.mkForce false;
    firewall.allowedTCPPorts = [ 2269 ];
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
        { Gateway = "fe80::1"; }
      ];
    };
  };

  system.activationScripts.adsbDockerCompose = {
    text = ''
      # Ensure directory exists (does not touch contents if already there)
      install -d -m0755 -o fred -g users /opt/adsb
      install -d -m0755 -o fred -g users /opt/adsb/imageapi
      install -d m0755 -o fred -g users /opt/adsb/imageapi/data/
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

    "docker/fredvps/fredsite.env" = {
      format = "yaml";
    };

    "github_api" = {
      mode = "0444";
    };
  };

  services = {
    openssh.ports = [ 2269 ];

    # Accept subnet routes advertised by sdrhub (192.168.31.0/24) so that
    # LAN services (Attic, Loki, etc.) are reachable without config changes.
    tailscale.extraUpFlags = [ "--accept-routes" ];

    fail2ban = {
      enable = true;
      maxretry = 5;
      bantime = "1h";
      bantime-increment = {
        enable = true;
        multipliers = "2";
        maxtime = "168h";
      };
      jails.sshd.settings = {
        enabled = true;
        port = "2269";
        filter = "sshd";
        maxretry = 3;
      };
    };

    adsb.containers = [
      ###############################################################
      # Fred Site
      ###############################################################
      {
        name = "fredsite";
        image = "ghcr.io/fredsystems/fred-site:latest-build-4";

        environmentFiles = [
          config.sops.secrets."docker/fredvps/fredsite.env".path
        ];

        ports = [ "4200:80" ];
      }
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
          "${config.sops.secrets.github_api.path}:/opt/api/sdre-e-updater.2024-02-05.private-key.pem:ro"
        ];

        ports = [ "3001:3000" ];
      }

      ###############################################################
      # tar1090
      ###############################################################
      {
        name = "tar1090";
        image = "ghcr.io/sdr-enthusiasts/docker-tar1090:latest-build-1415";

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
        image = "ghcr.io/sdr-enthusiasts/acars_router:latest-build-566";

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
        image = "ghcr.io/sdr-enthusiasts/docker-acarshub:latest-build-1484";

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
