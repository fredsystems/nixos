{
  config,
  stateVersion,
  ...
}:
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

          rewrites = [
            {
              enabled = true;
              domain = "sdrhub.lan";
              answer = "192.168.31.20";
            }
            {
              enabled = true;
              domain = "search.sdrhub.lan";
              answer = "192.168.31.20";
            }
            {
              enabled = true;
              domain = "acarshub.lan";
              answer = "192.168.31.24";
            }
            {
              enabled = true;
              domain = "fredhub.lan";
              answer = "192.168.31.14";
            }
            {
              enabled = true;
              domain = "fredvps.lan";
              answer = "5.161.253.151";
            }
            {
              enabled = true;
              domain = "hfdlhub1.lan";
              answer = "192.168.31.17";
            }
            {
              enabled = true;
              domain = "hfdlhub2.lan";
              answer = "192.168.31.19";
            }
            {
              enabled = true;
              domain = "vdlmhub.lan";
              answer = "192.168.31.23";
            }
          ];
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
        image = "amir20/dozzle:v10.5.1@sha256:2f8d5c2b6181533a58246313b1d840a69ae04e6c1010e2f6bb52c2228342b443";

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
      #   image = "ghcr.io/sdr-enthusiasts/airspy_adsb:latest-build-306@sha256:b52473eb760924dd468d025a4c650ff2617e5aa7cd7fd91d4584a67fa1558277";

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
        image = "ghcr.io/sdr-enthusiasts/docker-adsb-ultrafeeder:telegraf-build-922@sha256:e942b7329e18306e536b1e131cdc2e442726c20553e5576aa46681749cc86d59";

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
        image = "ghcr.io/sdr-enthusiasts/docker-dump978:telegraf-build-793@sha256:6a7ce596b76d8732647ea5c9d48cfa4cd14c26c65eca46a61cc64b36d6c99749";

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
        image = "ghcr.io/sdr-enthusiasts/docker-adsbhub:latest-build-521@sha256:a78da2e67efcc284f4caed9578b354afe35ef82479018d0cd39c4a47ef08c161";

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
        image = "ghcr.io/sdr-enthusiasts/docker-flightradar24:latest-build-845@sha256:ddd1ca0b59642a91d82a1f736ccdaaa5e5f3ffd5164160604667e7e256e30b24";

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
        image = "ghcr.io/sdr-enthusiasts/docker-piaware:latest-build-656@sha256:f271dde05940f5af5b36a5fc349c4575b9c17778d81c64127bf870738dbef388";

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
        image = "ghcr.io/sdr-enthusiasts/docker-planefinder:latest-build-530@sha256:fc2350ca99429494ba13a6e4cd755200866713e4e355399f1e24d33b3918fd38";

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
        image = "ghcr.io/sdr-enthusiasts/docker-radarvirtuel:latest-build-788@sha256:2411f01a92e9557f642eb2c602f18b1d03ee89de0ad3920ba92c258726a05c1f";

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
          "/etc/localtime:/etc/localtime:ro"
        ];
      }

      ###############################################################
      # RBFeeder / AirNav RadarBox
      ###############################################################
      {
        name = "rbfeeder";
        image = "ghcr.io/sdr-enthusiasts/docker-airnavradar:latest-build-873@sha256:95f0ab91e335b3af3b03ccab29822bc75a3b2fd23af28aa72f3605b19fc5f95c";

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
        image = "ghcr.io/sdr-enthusiasts/docker-opensky-network:latest-build-827@sha256:3ff4dc1426a83db24a3d13338a1381d4dfa64c48ea54dbeb94ce338756aee653";

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
        image = "ghcr.io/sdr-enthusiasts/docker-sdrmap:latest-build-90@sha256:29e98100c7f1d88bfd67e55c932a9915356f589840a4c5bc43e287121be296d0";

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
        image = "ghcr.io/sdr-enthusiasts/docker-acarshub:latest-build-1496@sha256:3603cfae55a28da51fecca250cc7dfae5ca957941fb48157081ef00e0a705c24";

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
        image = "ghcr.io/rpatel3001/docker-acars2pos:latest-build-30@sha256:3cbf55fa2b1d5fd8ba307404bbbc0a491dcfc9b5fd15e7b196e3d4e6dbd2a85f";

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
        image = "ghcr.io/fccview/degoog:0.16.0@sha256:4ddbc0074eeb3b454c327c0ff296b6acf3fdbfae5090ad59d5add18129226522";

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
        image = "ghcr.io/sdr-enthusiasts/acars_router:latest-build-575@sha256:7b15c958ba098962b4632ec792103d6e51b26f9088b834a7f6e9c26d0b5a58b8";

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

      virtualHosts.localhost = {
        root = ./html;

        locations = {
          "/" = {
            index = "index.html";
          };

          "/dozzle/" = {
            proxyPass = "http://192.168.31.20:9999";
            extraConfig = "proxy_redirect / /dozzle/;";
          };

          "/tar1090/" = {
            proxyPass = "http://192.168.31.20:8080/";
            extraConfig = "proxy_redirect / /tar1090/;";
          };

          "/dump978/" = {
            proxyPass = "http://192.168.31.20:8083/";
            extraConfig = "proxy_redirect / /dump978/;";
          };

          "/graphs/" = {
            proxyPass = "http://192.168.31.20:8080/graphs1090/";
          };

          "/fr24/" = {
            return = "http://192.168.31.20:8082/";
          };

          "/fr24" = {
            return = "http://192.168.31.20:8082/";
          };

          "/piaware/" = {
            proxyPass = "http://192.168.31.20:8084/";
            extraConfig = "proxy_redirect / /piaware/;";
          };

          "/planefinder/" = {
            return = "http://192.168.31.20:8087";
          };

          "/planefinder" = {
            return = "http://192.168.31.20:8087";
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

      virtualHosts."search.sdrhub.lan" = {
        locations."/" = {
          proxyPass = "http://127.0.0.1:4444";
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
