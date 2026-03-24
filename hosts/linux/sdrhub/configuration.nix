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
        image = "amir20/dozzle:v10.0.7@sha256:d383abf0fee72a8037d6ec6474424e56d752a52208e0ed70f4805e9d86a77830";

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
      #   image = "ghcr.io/sdr-enthusiasts/airspy_adsb:latest-build-299@sha256:11651aed48c5367cbe79ef4ff575bf56e2d75b79f3455da2e26878f6b9b24c3d";

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
        image = "ghcr.io/sdr-enthusiasts/docker-adsb-ultrafeeder:latest-build-900@sha256:6699ff5d282c1cca12333ad7562cda8e6af728f2fee89177191309f93500fdb3";

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
        image = "ghcr.io/sdr-enthusiasts/docker-dump978:telegraf-build-787@sha256:7fdc5710b7473e1f46c2dd04772c4323a944ebf227fb567eb18ec20d237cfbb9";

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
        image = "ghcr.io/sdr-enthusiasts/docker-adsbhub:latest-build-515@sha256:713023dec9ce43d99f4b5c9235aa308c9978694e37a074e6bdfed124c93d4c6f";

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
        image = "ghcr.io/sdr-enthusiasts/docker-flightradar24:latest-build-841@sha256:d1afccf9022462fe0cc9405791c5243e1c318d6dd167e00012ea168cfb105f06";

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
        image = "ghcr.io/sdr-enthusiasts/docker-piaware:latest-build-650@sha256:0983a99cd06fb8cce2ccac778023800bb2822ee8a8dd1d2158502c3f8ed30ec0";

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
        image = "ghcr.io/sdr-enthusiasts/docker-planefinder:latest-build-526@sha256:71f4957646dec888c4bfec08634b4cb22f26bed56c82f47fd9c97a6e341de5c0";

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
        image = "ghcr.io/sdr-enthusiasts/docker-radarvirtuel:latest-build-780@sha256:f91d03a4eb5f7b0d4615007df20841fe5c302db14ccd8dd40146862d1c7f53f0";

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
        image = "ghcr.io/sdr-enthusiasts/docker-airnavradar:latest-build-865@sha256:bae30b3ae8cf27e2cc2c432f2d22a71ba3317f2d4d4ad6c2ffeda76b96721667";

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
        image = "ghcr.io/sdr-enthusiasts/docker-opensky-network:latest-build-821@sha256:4ce01fddc622dff1eab85bd7838752ec68f3ff5f3afb5e81b041f84bf6a4248b";

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
        image = "ghcr.io/sdr-enthusiasts/docker-sdrmap:latest-build-82@sha256:016ddc9306a0adaed17334e38b125aaece2555e9e0751c3372b5aebcf15b4d22";

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
        image = "ghcr.io/sdr-enthusiasts/docker-acarshub:latest-build-1487@sha256:933cbab287f625d2e5b57527f904eee66b609fef3cc6b54caa1c112ccbfa365d";

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
        image = "ghcr.io/sdr-enthusiasts/docker-acarshub:v4-latest-build-64@sha256:a91ec2d0c0854c9c9116b2125c2b2c34fc412d776483c6d3170986874d6b29fb";

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
      # ACARS ROUTER (ACARS + VDLM2 + HFDL consolidation)
      ###############################################################
      {
        name = "acars_router";
        image = "ghcr.io/sdr-enthusiasts/acars_router:latest-build-569@sha256:33bfecf59eb6d1758c70b8165b313a35985a0afac27ff12d2f1233b1d655cf09";

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
    };
  };

  system.stateVersion = stateVersion;

  system.activationScripts.adsbDockerCompose = {
    text = ''
      # Ensure directory exists (does not touch contents if already there)
      install -d -m0755 -o fred -g users /opt/adsb
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
