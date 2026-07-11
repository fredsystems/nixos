{
  lib,
  pkgs,
  stateVersion,
  config,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
    ../../../profiles/adsb-hub.nix
    ../../../modules/services/tailscale
    ../../../modules/services/python-venv-app.nix
    ./nginx.nix
    ./discord-backup.nix
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
  };

  system.stateVersion = stateVersion;

  networking = {
    hostName = "fredvps";
    useNetworkd = true;
    useDHCP = false;
    networkmanager.enable = lib.mkForce false;
    firewall.allowedTCPPorts = [
      2269
      8078
    ];
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

    ###################################################################
    # Python venv services — code is manually `git clone`d to
    # /home/nik/<app>, dependencies are pinned in each app's
    # requirements.txt far behind what nixpkgs ships, so pip (not
    # nixpkgs) resolves them into a venv scoped to that directory.
    # See modules/services/python-venv-app.nix.
    ###################################################################
    pythonVenvApps = {
      test-site = {
        path = "/home/nik/test_site";
        user = "nik";
        # scipy==1.10.1 (pinned in requirements.txt) has no cp312+ wheel.
        python = pkgs.python311;
        execStart = "$VENV/bin/uvicorn app.main:app --host 0.0.0.0 --port 8078 --workers 2";
      };

      discord-bot = {
        path = "/home/nik/discord-bot";
        user = "nik";
        # matplotlib==3.7.5 (pinned in requirements.txt) has no cp313 wheel.
        python = pkgs.python312;
        execStart = "$VENV/bin/python main-discord.py";
      };
    };

    adsb.containers = [
      ###############################################################
      # Fred Site
      ###############################################################
      {
        name = "fredsite";
        image = "ghcr.io/fredsystems/fred-site:latest-build-8@sha256:53659b897364c139dc504e6824ae999febdfe96616fbf306b8681a493510ed81";

        environmentFiles = [
          config.sops.secrets."docker/fredvps/fredsite.env".path
        ];

        ports = [ "4200:80" ];
      }
      ###############################################################
      # DOZZLE AGENT
      ###############################################################
      (import ../../../modules/services/mk-dozzle-agent.nix { })

      ###############################################################
      # IMAGE API
      ###############################################################
      {
        name = "imageapi";
        image = "ghcr.io/sdr-enthusiasts/sdre-image-api:latest-build-5@sha256:80348b6e70a864f44816660bc2fc61c40d0d415872d060c40731198ab09a6c7f";

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
        image = "ghcr.io/sdr-enthusiasts/docker-tar1090:telegraf-build-1460@sha256:5c23cc03b277f9f7f6549df03e3618bdc1ff8b7b9e83183b91963d7bab4c0969";

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
        image = "ghcr.io/sdr-enthusiasts/acars_router:latest-build-584@sha256:5fb5fc32de161c949010da9504b6fb77c0158bc25c5ed80b5d16e97aab317cae";

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
        image = "ghcr.io/sdr-enthusiasts/docker-acarshub:latest-build-1502@sha256:b0d8a9bc85771bb7cd85341fc27a7f87d9f9cd742703722b156b8944582f58b8";

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
