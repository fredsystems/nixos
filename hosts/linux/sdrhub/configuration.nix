{
  config,
  stateVersion,
  lib,
  ...
}:
let
  # Map of <bare hostname> -> <answer IP>. Each entry produces both
  # `<name>.lan` and `<name>.local` AdGuard rewrites so that either
  # TLD works on the LAN. Keep this in sync with the nginx vhosts
  # below (which use matching serverAliases).
  lanHosts = {
    "sdrhub" = "192.168.31.20";
    "ai.sdrhub" = "192.168.31.20";
    "search.sdrhub" = "192.168.31.20";
    "tar1090.sdrhub" = "192.168.31.20";
    "dump978.sdrhub" = "192.168.31.20";
    "piaware.sdrhub" = "192.168.31.20";
    "acarshub" = "192.168.31.24";
    "fredhub" = "192.168.31.14";
    "fredvps" = "5.161.253.151";
    "hfdlhub1" = "192.168.31.19";
    "hfdlhub2" = "192.168.31.17";
    "vdlmhub" = "192.168.31.23";
  };

  mkRewrites =
    hosts:
    lib.concatLists (
      lib.mapAttrsToList (name: ip: [
        {
          enabled = true;
          domain = "${name}.lan";
          answer = ip;
        }
        {
          enabled = true;
          domain = "${name}.local";
          answer = ip;
        }
      ]) hosts
    );
in
{
  imports = [
    ./hardware-configuration.nix
    ../../../modules/secrets/sops.nix
    ../../../modules/services/adsb-docker-units.nix
    ../../../modules/monitoring/master
    ../../../modules/monitoring/agent
    ../../../modules/services/tailscale
  ];

  deployment.role = "monitoring-master";

  sops_secrets.enable_secrets.enable = true;

  networking.hostName = "sdrhub";

  # Advertise the LAN subnet over Tailscale so that fredvps can reach
  # LAN-only services (Attic at 192.168.31.14, Loki at 192.168.31.20, etc.)
  # without any changes to those configs.
  # NOTE: after deploying, approve the advertised route in the Tailscale admin
  # console under Machines -> sdrhub -> Edit route settings.
  services.tailscale.extraUpFlags = [ "--advertise-routes=192.168.31.0/24" ];

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

  ###########################################
  # Firewall
  ###########################################
  networking = {
    firewall = {
      allowedTCPPorts = [
        80
      ];
      allowedUDPPorts = [ 53 ];
    };
  };

  services = {
    ###########################################
    # Unbound DNS Resolver
    ###########################################
    unbound = {
      enable = true;

      settings = {
        server = {
          interface = [ "127.0.0.1" ];
          port = 5335;
          access-control = [ "127.0.0.1 allow" ];

          harden-glue = true;
          harden-dnssec-stripped = true;
          use-caps-for-id = false;
          prefetch = true;
          edns-buffer-size = 1232;
          tls-system-cert = true;
          tls-use-sni = true;

          hide-identity = true;
          hide-version = true;
        };

        forward-zone = [
          # Tailscale MagicDNS — must be listed before the catch-all "." zone
          # so Unbound routes tailnet queries to Tailscale's resolver (100.100.100.100)
          # rather than Quad9, which has no knowledge of private MagicDNS names.
          {
            name = "tailc21fc7.ts.net";
            forward-addr = [ "100.100.100.100" ];
            forward-tls-upstream = false;
          }
          {
            name = ".";
            forward-addr = [
              "9.9.9.11@853#dns11.quad9.net"
              "149.112.112.11@853#dns11.quad9.net"
            ];
            forward-tls-upstream = true;
            forward-first = false;
          }
        ];
      };
    };

    ###########################################
    # AdGuard Home (local upstream = Unbound)
    ###########################################
    adguardhome = {
      enable = true;
      openFirewall = true;

      settings = {
        http.address = "127.0.0.1:3003";

        dns = {
          upstream_dns = [ "127.0.0.1:5335" ];
          enable_dnssec = true;
          rate_limit = 0;

          edns_client_subnet = {
            enabled = true;
          };
        };

        filtering = {
          protection_enabled = true;
          filtering_enabled = true;
          parental_enabled = false;
          safe_search.enabled = false;

          rewrites = mkRewrites lanHosts;
        };

        user_rules = [
          "@@||mask.icloud.com^"
          "@@||mask-h2.icloud.com^"
          "@@||mask-canary.icloud.com^"
          "@@||canary.mask.apple-dns.net^"
          "@@||s.youtube.com^"
          "@@||video-stats.l.google.com^"
          "@@||facebook.com^"
          "@@||fbcdn.net^"
          "@@||instagram.c10r.instagram.com^"
          "@@||instagram.com^"
          "@@||i.instagram.com^"
          "@@||cdninstagram.com^"
          "@@||fonts.gstatic.com^$important"
          "@@||analysis.chess.com^"
          "@@||stunnel.org^"
          "@@||tailscale.com^"
          "@@||tailscale.io^"
          "@@||controlplane.tailscale.com^"
          "@@||log.tailscale.io^"
          "@@||tailc21fc7.ts.net^"
          "@@||protonvpn.net"
          "@@||protonvpn.com"
        ];

        filters =
          map
            (url: {
              enabled = true;
              inherit url;
            })
            [
              "https://adguardteam.github.io/HostlistsRegistry/assets/filter_9.txt"
              "https://adguardteam.github.io/HostlistsRegistry/assets/filter_11.txt"
              "https://github.com/ppfeufer/adguard-filter-list/blob/master/blocklist?raw=true"
            ];
      };
    };
    adsb.containers = [

      ###############################################################
      # DOZZLE (UI)
      ###############################################################
      {
        name = "dozzle";
        image = "amir20/dozzle:v10.6.7@sha256:43d933ebda116990c920e054d68a1aed286ab01fd31657983c53bbdf46cc0aa8";

        restart = "always";

        environmentFiles = [
          config.sops.secrets."docker/sdrhub/dozzle.env".path
        ];

        ports = [
          "9999:8080"
        ];

        requires = [ "network-online.target" ];
        after = [ "network-online.target" ];
      }

      ###############################################################
      # DOZZLE AGENT
      ###############################################################
      (import ../../../modules/services/mk-dozzle-agent.nix {
        port = "3939:7007";
      })

      ###############################################################
      # AIRSPY ADS-B RECEIVER
      ###############################################################
      # {
      #   name = "airspy_adsb";
      #   image = "ghcr.io/sdr-enthusiasts/airspy_adsb:latest-build-312@sha256:821e9b875fd00e072eef9fb709a8619d6879f8cd77b17e1ce98e94d68fae8bdf";

      #   hostname = "airspy_adsb";
      #   restart = "always";
      #   tty = false;

      #   environmentFiles = [
      #     config.sops.secrets."docker/sdrhub/airspy_adsb.env".path
      #   ];

      #   deviceCgroupRules = [
      #     "c 189:* rwm"
      #   ];

      #   volumes = [
      #     "/dev:/dev"
      #     "/opt/adsb/data/airspy_adsb:/run/airspy_adsb"
      #   ];
      # }

      ###############################################################
      # ULTRAFEEDER (readsb) — central ADS-B decoder
      ###############################################################
      {
        name = "ultrafeeder";
        image = "ghcr.io/sdr-enthusiasts/docker-adsb-ultrafeeder:latest-build-939@sha256:38b6e1e355c0ffffbe72ce717276c18389a3f477d2744fac58a07b5f4bc02832";

        hostname = "ultrafeeder";
        restart = "always";
        tty = false;

        environmentFiles = [
          config.sops.secrets."docker/sdrhub/ultrafeeder.env".path
        ];

        deviceCgroupRules = [
          "c 189:* rwm"
        ];

        ports = [
          "8080:80"
          "30002:30002"
          "30003:30003"
          "30005:30005"
          "30047:30047"
          "12000:12000"
          "9273-9274:9273-9274"
        ];

        volumes = [
          "/opt/adsb/data/ultra_globe_history:/var/globe_history"
          "/opt/adsb/data/ultra_graphs1090:/var/lib/collectd"
          "/proc/diskstats:/proc/diskstats:ro"
          "/dev:/dev"
          "/sys/class/thermal/thermal_zone2:/sys/class/thermal/thermal_zone0:ro"
          "/opt/adsb/data/airspy_adsb:/run/airspy_adsb"
        ];

        tmpfs = [
          "/run:exec,size=256M"
          "/tmp:size=128M"
          "/var/log:size=32M"
        ];
      }

      ###############################################################
      # dump978 — UAT / 978 MHz decoder
      ###############################################################
      {
        name = "dump978";
        image = "ghcr.io/sdr-enthusiasts/docker-dump978:telegraf-build-799@sha256:50c04494601c5bf908288f3590900cdd45e13d9fd4c5effcb7a26373963f3c49";

        hostname = "dump978";
        restart = "always";
        tty = true;

        environmentFiles = [
          config.sops.secrets."docker/sdrhub/dump978.env".path
        ];

        deviceCgroupRules = [
          "c 189:* rwm"
        ];

        ports = [
          "8083:80"
          "9275:9275"
        ];

        volumes = [
          "/opt/adsb/data/dump978_autogain:/var/globe_history"
          "/dev:/dev"
        ];

        tmpfs = [
          "/run/readsb"
          "/var/log"
        ];
      }

      ###############################################################
      # ADSBHub feeder
      ###############################################################
      {
        name = "adsbhub";
        image = "ghcr.io/sdr-enthusiasts/docker-adsbhub:latest-build-527@sha256:7f896c932362121a3760f00e2b20e6e8a3f0e0fe82d2a8cd67f7bf4c61ffcb14";

        restart = "always";
        tty = true;

        environmentFiles = [
          config.sops.secrets."docker/sdrhub/adsbhub.env".path
        ];

        tmpfs = [
          "/run:exec,size=64M"
          "/var/log"
        ];
      }

      ###############################################################
      # Flightradar24 feeder
      ###############################################################
      {
        name = "fr24";
        image = "ghcr.io/sdr-enthusiasts/docker-flightradar24:latest-build-855@sha256:f329680660f8c72885061955353735f6d9b8d261fb77ee0ba60f277f7a0630f1";

        restart = "always";
        tty = true;

        ports = [
          "8082:8754"
        ];

        environmentFiles = [
          config.sops.secrets."docker/sdrhub/fr24.env".path
        ];

        tmpfs = [
          "/run:exec,size=64M"
          "/var/log"
        ];
      }

      ###############################################################
      # PiAware (FlightAware)
      ###############################################################
      {
        name = "piaware";
        image = "ghcr.io/sdr-enthusiasts/docker-piaware:latest-build-663@sha256:8d3298cfd60002309aca06b636984f23a3be6dddabd8c81a3b07948499143015";

        hostname = "piaware";
        restart = "always";
        tty = true;

        ports = [
          "8084:80"
        ];

        environmentFiles = [
          config.sops.secrets."docker/sdrhub/piaware.env".path
        ];

        tmpfs = [
          "/run:exec,size=64M"
          "/var/log"
        ];
      }

      ###############################################################
      # PlaneFinder feeder
      ###############################################################
      {
        name = "planefinder";
        image = "ghcr.io/sdr-enthusiasts/docker-planefinder:latest-build-538@sha256:974f64a1e1629dabffdd440082248ff0f17a9a501a6439523066907be9799d38";

        restart = "always";
        tty = true;

        ports = [
          "8087:30053"
        ];

        environmentFiles = [
          config.sops.secrets."docker/sdrhub/planefinder.env".path
        ];

        tmpfs = [
          "/run:exec,size=64M"
          "/var/log"
        ];
      }

      ###############################################################
      # PlaneWatch feeder
      ###############################################################
      {
        name = "planewatch";
        image = "ghcr.io/plane-watch/docker-plane-watch:v0.0.6@sha256:a7e4e13af03852900624f1a6bd193d697ae3c9d684bfeb3b817dcc680db2656f";

        restart = "always";
        tty = true;

        environmentFiles = [
          config.sops.secrets."docker/sdrhub/planewatch.env".path
        ];

        tmpfs = [
          "/run:exec,size=64M"
          "/var/log"
        ];
      }

      ###############################################################
      # RadarVirtuel feeder
      ###############################################################
      {
        name = "radarvirtuel";
        image = "ghcr.io/sdr-enthusiasts/docker-radarvirtuel:latest-build-797@sha256:1f6543e1725431222bd440d05641f9d0c578801087e05003e2d274b1e657bc34";

        hostname = "radarvirtuel";
        restart = "always";
        tty = true;

        environmentFiles = [
          config.sops.secrets."docker/sdrhub/radarvirtuel.env".path
        ];

        tmpfs = [
          "/tmp:rw,nosuid,nodev,noexec,relatime,size=128M"
          "/run:exec,size=64M"
          "/var/log"
        ];

        volumes = [
          "/opt/adsb/data/radarvirtuel:/data:rw"
          "/opt/adsb/data/fake_cpuinfo:/proc/cpuinfo:ro"
          "/etc/localtime:/etc/localtime:ro"
          "/etc/timezone:/etc/timezone:ro"
        ];
      }

      ###############################################################
      # RBFeeder / AirNav RadarBox
      ###############################################################
      {
        name = "rbfeeder";
        image = "ghcr.io/sdr-enthusiasts/docker-airnavradar:latest-build-879@sha256:aba3c318d5496466628526d6ea7440ea6a2c065d9ea2093a423ed3217ef2c3a3";

        restart = "always";
        tty = false;

        environmentFiles = [
          config.sops.secrets."docker/sdrhub/rbfeeder.env".path
        ];

        volumes = [
          "/opt/adsb/data/fake_cpuinfo:/proc/cpuinfo"
          "/sys/class/thermal/thermal_zone2:/sys/class/thermal/thermal_zone0:ro"
        ];

        tmpfs = [
          "/run:exec,size=64M"
          "/var/log"
        ];
      }

      ###############################################################
      # OpenSky Network Feeder
      ###############################################################
      {
        name = "opensky";
        image = "ghcr.io/sdr-enthusiasts/docker-opensky-network:latest-build-833@sha256:d0a0aa79445eea3e79f23b950c061f0dc6bb7a6c9de4a81c035d32331a564644";

        restart = "always";
        tty = true;

        environmentFiles = [
          config.sops.secrets."docker/sdrhub/opensky.env".path
        ];

        tmpfs = [
          "/run:exec,size=64M"
          "/var/log"
        ];
      }

      ###############################################################
      # SDRMAP
      ###############################################################
      {
        name = "sdrmap";
        image = "ghcr.io/sdr-enthusiasts/docker-sdrmap:latest-build-96@sha256:57c87f930333f2d9f9a40306c3d2277711da363ffc7354b674843d10b6bb8c40";

        restart = "always";

        environmentFiles = [
          config.sops.secrets."docker/sdrhub/sdrmap.env".path
        ];
      }

      ###############################################################
      # ACARSHUB (ACARS/VHFM/VDLM ingestion + UI)
      ###############################################################
      {
        name = "acarshub";
        image = "ghcr.io/sdr-enthusiasts/docker-acarshub:latest-build-1502@sha256:b0d8a9bc85771bb7cd85341fc27a7f87d9f9cd742703722b156b8944582f58b8";

        restart = "always";
        tty = true;

        ports = [
          "8085:80"
        ];

        environmentFiles = [
          config.sops.secrets."docker/sdrhub/acarshub.env".path
        ];

        volumes = [
          "/opt/adsb/data/acarshub:/run/acars"
        ];

        tmpfs = [
          "/database:exec,size=64M"
          "/run:exec,size=64M"
          "/var/log"
        ];
      }

      ###############################################################
      # ACARSHUB v4 (ACARS/VHFM/VDLM ingestion + UI)
      ###############################################################
      {
        name = "acarshubv4";
        image = "ghcr.io/sdr-enthusiasts/docker-acarshub:v4-latest-build-68@sha256:afd958ba4efa1d460c430eb8331c12598008dd9e5f6d15215f4c2fec6d70ea08";

        restart = "always";
        tty = true;

        ports = [
          "8086:80"
        ];

        environmentFiles = [
          config.sops.secrets."docker/sdrhub/acarshub.env".path
        ];

        volumes = [
          "/opt/adsb/data/acarshubv4:/run/acars"
        ];

        tmpfs = [
          "/database:exec,size=64M"
          "/run:exec,size=64M"
          "/var/log"
        ];
      }

      {
        name = "acars2pos";
        image = "ghcr.io/rpatel3001/docker-acars2pos:latest-build-31@sha256:229f6ee8a65a25989aacf62e2f93b30dff86066a9684396e599a95ccb049b834";

        restart = "always";
        tty = true;

        environmentFiles = [
          config.sops.secrets."docker/sdrhub/acars2pos.env".path
        ];

        tmpfs = [
          "/database:exec,size=64M"
          "/run:exec,size=64M"
          "/var/log"
        ];
      }

      ###############################################################
      # DEGOOG (search engine aggregator)
      ###############################################################
      {
        name = "degoog";
        image = "ghcr.io/fccview/degoog:0.22.0@sha256:2c58290bc980fd1f299520bd2b82753dc21356d18eb59d16c933c216578ad419";

        restart = "always";

        # 0.10.0 entrypoint starts as root, chowns /app/data, then drops
        # to PUID/PGID.  Do NOT pass --user; let the entrypoint handle it.
        environment = {
          PUID = "1000";
          PGID = "1000";
        };

        ports = [
          "4444:4444"
        ];

        volumes = [
          "/opt/adsb/degoog:/app/data"
        ];
      }

      ###############################################################
      # ACARS ROUTER (ACARS + VDLM2 + HFDL consolidation)
      ###############################################################
      {
        name = "acars_router";
        image = "ghcr.io/sdr-enthusiasts/acars_router:latest-build-584@sha256:5fb5fc32de161c949010da9504b6fb77c0158bc25c5ed80b5d16e97aab317cae";

        restart = "always";
        tty = true;

        ports = [
          "15550:15550"
          "15555:15555"
          "15556:15556"
          "35550:35550"
          "35555:35555"
          "35556:35556"
          "45550:45550"
          "45555:45555"
          "45556:45556"
          "5550:5550"
          "5556:5556"
        ];

        environmentFiles = [
          config.sops.secrets."docker/sdrhub/acars_router.env".path
        ];

        tmpfs = [
          "/run:exec,size=64M"
          "/var/log"
        ];
      }

    ];

    ###########################################
    # NGINX Reverse Proxy
    ###########################################
    nginx = {
      enable = true;
      recommendedGzipSettings = true;
      recommendedOptimisation = true;
      recommendedProxySettings = true;

      appendHttpConfig = ''
        map $http_upgrade $connection_upgrade {
          default upgrade;
          "" close;
        }
      '';

      virtualHosts = {
        # Landing page — bound to sdrhub.lan AND set as the default server
        # so any unknown Host header (e.g. raw IP) also gets the dashboard
        # instead of accidentally hitting ai.sdrhub.lan / OpenWebUI.
        "sdrhub.lan" = {
          default = true;
          serverAliases = [
            "localhost"
            "sdrhub.local"
          ];
          root = ./html;

          locations = {
            "/" = {
              index = "index.html";
            };

            "/dozzle/" = {
              proxyPass = "http://192.168.31.20:9999";
              extraConfig = "proxy_redirect / /dozzle/;";
            };

            "/graphs/" = {
              proxyPass = "http://192.168.31.20:8080/graphs1090/";
            };

            "/fr24/" = {
              return = "302 http://192.168.31.20:8082/";
            };

            "/fr24" = {
              return = "302 http://192.168.31.20:8082/";
            };

            "/planefinder/" = {
              return = "302 http://192.168.31.20:8087/";
            };

            "/planefinder" = {
              return = "302 http://192.168.31.20:8087/";
            };

            "/acarshub/" = {
              proxyPass = "http://192.168.31.20:8085/";
              extraConfig = ''
                proxy_http_version 1.1;
                proxy_set_header Upgrade $http_upgrade;
                proxy_set_header Connection $connection_upgrade;
              '';
            };

            "/acarshub-test/" = {
              proxyPass = "http://192.168.31.20:8086/";
              extraConfig = ''
                proxy_http_version 1.1;
                proxy_set_header Upgrade $http_upgrade;
                proxy_set_header Connection $connection_upgrade;
              '';
            };
          };
        };

        # tar1090, dump978 and piaware all serve assets from absolute
        # paths (/data, /chunks, /db, ...). Sub-path proxying breaks them,
        # so give each its own vhost. Update your landing page links to
        # http://tar1090.sdrhub.lan, http://dump978.sdrhub.lan, etc.
        "tar1090.sdrhub.lan" = {
          serverAliases = [ "tar1090.sdrhub.local" ];
          locations."/".proxyPass = "http://192.168.31.20:8080";
        };

        "dump978.sdrhub.lan" = {
          serverAliases = [ "dump978.sdrhub.local" ];
          locations."/".proxyPass = "http://192.168.31.20:8083";
        };

        "piaware.sdrhub.lan" = {
          serverAliases = [ "piaware.sdrhub.local" ];
          locations."/".proxyPass = "http://192.168.31.20:8084";
        };

        "ai.sdrhub.lan" = {
          serverAliases = [ "ai.sdrhub.local" ];
          locations."/" = {
            proxyPass = "http://192.168.31.14:8889";
          };
        };
        "search.sdrhub.lan" = {
          serverAliases = [ "search.sdrhub.local" ];
          locations."/" = {
            proxyPass = "http://127.0.0.1:4444";
          };
        };
      };
    };
  };

  system.stateVersion = stateVersion;

  system.activationScripts.adsbDockerCompose = {
    text = ''
      # Ensure directory exists (does not touch contents if already there)
      install -d -m0755 -o fred -g users /opt/adsb
      install -d -m0755 -o fred -g users /opt/adsb/degoog
    '';
    deps = [ ];
  };

  sops.secrets = {
    "docker/sdrhub/dozzle.env" = {
      format = "yaml";
    };

    "docker/sdrhub/dozzle-agent.env" = {
      format = "yaml";
    };

    "docker/sdrhub/airspy_adsb.env" = {
      format = "yaml";
    };

    "docker/sdrhub/ultrafeeder.env" = {
      format = "yaml";
    };

    "docker/sdrhub/dump978.env" = {
      format = "yaml";
    };

    "docker/sdrhub/adsbhub.env" = {
      format = "yaml";
    };

    "docker/sdrhub/fr24.env" = {
      format = "yaml";
    };

    "docker/sdrhub/piaware.env" = {
      format = "yaml";
    };

    "docker/sdrhub/planefinder.env" = {
      format = "yaml";
    };

    "docker/sdrhub/planewatch.env" = {
      format = "yaml";
    };

    "docker/sdrhub/radarvirtuel.env" = {
      format = "yaml";
    };

    "docker/sdrhub/rbfeeder.env" = {
      format = "yaml";
    };

    "docker/sdrhub/opensky.env" = {
      format = "yaml";
    };

    "docker/sdrhub/sdrmap.env" = {
      format = "yaml";
    };

    "docker/sdrhub/acarshub.env" = {
      format = "yaml";
    };

    "docker/sdrhub/acars_router.env" = {
      format = "yaml";
    };

    "docker/sdrhub/acars2pos.env" = {
      format = "yaml";
    };
  };
}
