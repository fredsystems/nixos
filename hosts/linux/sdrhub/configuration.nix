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
    "karma.sdrhub" = "192.168.31.20";
    "tar1090.sdrhub" = "192.168.31.20";
    "dump978.sdrhub" = "192.168.31.20";
    "piaware.sdrhub" = "192.168.31.20";
    "jellyfin.sdrhub" = "192.168.31.20";
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
    ../../../modules/hardware/usbfs.nix
  ];

  deployment.role = "monitoring-master";

  # This host has USB SDR hardware attached; raise the global usbfs
  # transfer-buffer ceiling above the 16 MB kernel default.
  hardware-profile.usbfs.enable = true;

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
        6379
        5432
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
        remote-control = {
          control-enable = true;
        };

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
        image = "amir20/dozzle:v10.6.14@sha256:1c1060cfb5402093c4e0f03f3534d7deaffeb0a6f6dd034e7c5f244603f35fb3";

        restart = "always";

        environmentFiles = [
          config.sops.secrets."docker/sdrhub/dozzle.env".path
        ];

        ports = [
          "9999:8080"
        ];

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
      #   image = "ghcr.io/sdr-enthusiasts/airspy_adsb:latest-build-315@sha256:ef616c9c565d6227958f41e8b6cacabfe65ae4f4a22708dda53d39a6a8faa2ac";

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
        image = "ghcr.io/sdr-enthusiasts/docker-adsb-ultrafeeder:telegraf-build-952@sha256:365bef756368e522935c1bd0005f9107f4b71fa9ce904da7f071e32ef27a5c17";

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
        # telegraf-build-801, not latest-build-801: the same application build,
        # but the `latest-*` variant does not ship the telegraf binary, and both
        # the telegraf and telegraf_socat s6 services `sleep infinity` without
        # it. That made ENABLE_PROMETHEUS / PROMETHEUSPORT / PROMETHEUSPATH
        # silently inert -- the s6 services reported "up" while nothing listened
        # on 9275, so the published port accepted connections via docker-proxy
        # and immediately reset them.
        #
        # With the binary present, /etc/s6-overlay/scripts/04-telegraf generates
        # outputs_prometheus.conf from those same env vars, which are already
        # set correctly below, so no other change is needed.
        #
        # Cost: the telegraf binary is ~310 MB uncompressed.
        image = "ghcr.io/sdr-enthusiasts/docker-dump978:telegraf-build-802@sha256:0120c49e2153d25d3b0b81734d4aadbb29deef26c5c3c05d718d4d9cfcb0388a";

        hostname = "dump978";
        restart = "always";
        tty = true;

        environmentFiles = [
          config.sops.secrets."docker/sdrhub/dump978.env".path
        ];

        # Suppress telegraf's per-aircraft socket listener.
        #
        # Without this, telegraf emits 23 metric families keyed on `address`,
        # `callsign` and `flightplan_id` -- one set per aircraft seen. That is
        # unbounded cardinality: observed growing from 230 to 286 series within
        # an hour, and with 90d retention every aircraft ever seen would leave
        # 23 series behind permanently. It is also useless for monitoring;
        # per-aircraft state is what tar1090 and skyaware978 are for.
        #
        # The aggregate inputs (stats_*, polar_range_*) are unaffected and are
        # what the scrape job actually wants: total_accepted_messages,
        # total_tracks, tracks_with_position, avg_accepted_rssi, max_distance_m.
        environment = {
          INFLUXDB_SKIP_AIRCRAFT = "true";
        };

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
        image = "ghcr.io/sdr-enthusiasts/docker-adsbhub:latest-build-530@sha256:ca7615a577deb94be5b3a004c80fc291f325ec767802edf057ad0944596cf01a";

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
        image = "ghcr.io/sdr-enthusiasts/docker-flightradar24:latest-build-859@sha256:998a80cc35b2db150843d1dece7dc99cb985d136503de9b46bc98c2f836030c5";

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
        image = "ghcr.io/sdr-enthusiasts/docker-piaware:latest-build-666@sha256:3b6772353a562f3d6ac1ba6a2281f96b173a43b822fda14c7f0218a459c225aa";

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
        image = "ghcr.io/sdr-enthusiasts/docker-planefinder:latest-build-541@sha256:1554ef9a9e34ea38c7765a4871afda9736cf85a47a60edb59e7eb43c4fc895c7";

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
        image = "ghcr.io/plane-watch/docker-plane-watch:v0.0.10@sha256:f8cc3254943c3f0cd8b97d448bee929c87f3c78b9ecf1a61a255343797e61745";

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
        image = "ghcr.io/sdr-enthusiasts/docker-radarvirtuel:latest-build-800@sha256:428a60bb83f61eaea7e351b6a1dd65573da828b716fcd94dacc593e5cf238b4e";

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
        image = "ghcr.io/sdr-enthusiasts/docker-airnavradar:latest-build-883@sha256:ccbd54e6bc146c9aacb304a54ff2c1671952fb3df71849afa5917a3b15eaab56";

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
        image = "ghcr.io/sdr-enthusiasts/docker-opensky-network:latest-build-844@sha256:3db40e3942781387711ef08696112e0ff5f398bb86406023c1734d5aef3a92b7";

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
        image = "ghcr.io/sdr-enthusiasts/docker-sdrmap:latest-build-99@sha256:d53cede29cf07e607fa06ac8fe86deb53b2bdf8cdc22783aa2db3de33c886fb3";

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
        image = "ghcr.io/sdr-enthusiasts/docker-acarshub:latest-build-1506@sha256:1ae9bb712fb3cbbc812da354431961812215306810675707277a319b07d52a91";

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
        image = "ghcr.io/sdr-enthusiasts/docker-acarshub:v4-latest-build-72@sha256:44e2e8f29e456dcc3d9316dab2b8169c6b5f4b46885eb307673790d970908e5b";

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
        image = "ghcr.io/fccview/degoog:0.24.0@sha256:79409f76137734baa0516a58def96e4d3842f6db26d813e75365dea8a00974e9";

        restart = "always";

        # 0.10.0 entrypoint starts as root, chowns /app/data, then drops
        # to PUID/PGID.  Do NOT pass --user; let the entrypoint handle it.
        environment = {
          PUID = "1000";
          PGID = "1000";
          DEGOOG_SETTINGS_PASSWORDS = "fred";
          DEGOOG_PUBLIC_INSTANCE = "false";
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
        image = "ghcr.io/sdr-enthusiasts/acars_router:latest-build-587@sha256:de236bc97c84e34679d2d0086524d9ebe2dc2252ed47799916a04e19578e4a67";

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

            # Karma serves its assets from absolute paths, so a sub-path proxy
            # would break them. Redirect to the dedicated vhost instead, the
            # same approach used for fr24 and planefinder above.
            "/karma/" = {
              return = "302 http://karma.sdrhub.lan/";
            };

            "/karma" = {
              return = "302 http://karma.sdrhub.lan/";
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
        "jellyfin.sdrhub.lan" = {
          serverAliases = [ "jellyfin.sdrhub.local" ];
          locations."/" = {
            proxyPass = "http://192.168.31.14:8096";
          };
        };
        "search.sdrhub.lan" = {
          serverAliases = [ "search.sdrhub.local" ];
          locations."/" = {
            proxyPass = "http://127.0.0.1:4444";
          };
        };

        # Karma alert dashboard. Bound to loopback by
        # modules/monitoring/master/karma.nix and reached only through here, so
        # it needs no firewall port of its own. The port is read from the
        # service definition rather than hardcoded.
        #
        # Karma pushes live alert updates over a websocket, hence the upgrade
        # headers (the $connection_upgrade map is defined in appendHttpConfig).
        "karma.sdrhub.lan" = {
          serverAliases = [ "karma.sdrhub.local" ];
          locations."/" = {
            proxyPass = "http://127.0.0.1:${toString config.services.karma.settings.listen.port}";
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
