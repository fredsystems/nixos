{
  config,
  stateVersion,
  lib,
  pkgs,
  ...
}:
let
  # Throwaway certificate for the catch-all 443 server block below. There is
  # no real name to get an ACME certificate for unmatched SNI, and the point
  # is only to avoid handing a *real* vhost's certificate to a client that
  # asked for a name we do not serve.
  snakeoilCert =
    pkgs.runCommand "nginx-default-snakeoil-cert" { nativeBuildInputs = [ pkgs.openssl ]; }
      ''
        mkdir -p "$out"
        openssl req -x509 -nodes -newkey rsa:2048 -days 36500 \
          -keyout "$out/key.pem" -out "$out/cert.pem" \
          -subj "/CN=invalid"
      '';

  # Restart the consuming container when its --env-file secret changes.
  # See modules/services/mk-container-secret.nix for why this is declared
  # here rather than derived inside adsb-docker-units.nix.
  inherit (import ../../../modules/services/mk-container-secret.nix)
    mkContainerSecret
    mkContainerSecrets
    ;

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
    "clipboard.sdrhub" = "192.168.31.20";
    "acarshub" = "192.168.31.24";
    "fredhub" = "192.168.31.14";
    "fredvps" = "5.161.253.151";
    "hfdlhub1" = "192.168.31.19";
    "hfdlhub2" = "192.168.31.17";
    "vdlmhub" = "192.168.31.23";
    "nvrhub" = "192.168.31.179";
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

  # The zone the wildcard certificate in ./acme.nix is issued for.
  #
  # This string must equal that certificate's name, because `useACMEHost`
  # below is keyed on it. Drift does NOT fail evaluation on its own -- the
  # nginx module would quietly declare a *second* certificate under whatever
  # name it was given, inheriting a null dnsProvider, and that only surfaces
  # as a failed issuance on the host. The assertion at the bottom of this file
  # turns that into a build error instead.
  internalDomain = "int.fredsystems.org";

  # Every nginx vhost on this host, keyed by the label it takes under
  # `internalDomain`. Each entry produces TWO server blocks:
  #
  #   <label>.int.fredsystems.org   the real one -- TLS, ACME, the proxying
  #   <legacy names>                a 308 to it, so old links keep working
  #
  # Generating both from one definition is the point: the serving config
  # exists once, so the two cannot drift, and retiring the plaintext layer
  # later is a matter of deleting `legacy` rather than deleting a vhost and
  # hoping nothing referenced it.
  #
  # Fields:
  #   legacy         plaintext names that must keep working. Head becomes the
  #                  server block's name, tail its serverAliases.
  #   legacyDefault  make the plaintext block port 80's default_server.
  #   vhost          the serving configuration; gains forceSSL + useACMEHost.
  migratedVhosts = {
    # Landing page. Also the plaintext default, so an unknown Host (a raw IP,
    # say) still lands here rather than on whichever vhost sorts first.
    sdrhub = {
      legacyDefault = true;
      legacy = [
        "sdrhub.lan"
        "sdrhub.local"
        "localhost"
      ];
      vhost = {
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

          # fr24 and planefinder are reached on their published container
          # ports, with no vhost of their own, so these redirects stay
          # plaintext. Giving them names under internalDomain would be a
          # straightforward follow-up; they are feeder status pages carrying
          # no credentials, which is why they are not in this pass.
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

          # Karma serves its assets from absolute paths, so a sub-path proxy
          # would break them. Redirect to the dedicated vhost instead, the
          # same approach used for fr24 and planefinder above.
          "/karma/" = {
            return = "302 https://karma.${internalDomain}/";
          };

          "/karma" = {
            return = "302 https://karma.${internalDomain}/";
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

    # tar1090, dump978 and piaware all serve assets from absolute paths
    # (/data, /chunks, /db, ...). Sub-path proxying breaks them, so each keeps
    # its own vhost.
    tar1090 = {
      legacy = [
        "tar1090.sdrhub.lan"
        "tar1090.sdrhub.local"
      ];
      vhost.locations."/".proxyPass = "http://192.168.31.20:8080";
    };

    dump978 = {
      legacy = [
        "dump978.sdrhub.lan"
        "dump978.sdrhub.local"
      ];
      vhost.locations."/".proxyPass = "http://192.168.31.20:8083";
    };

    piaware = {
      legacy = [
        "piaware.sdrhub.lan"
        "piaware.sdrhub.local"
      ];
      vhost.locations."/".proxyPass = "http://192.168.31.20:8084";
    };

    # OpenWebUI on fredhub. Carries a login and chat history, so this is one
    # of the three that motivated migrating the rest of the host.
    #
    # NOTE: TLS here covers client -> sdrhub only. The proxy_pass to fredhub
    # is still plaintext across the LAN, so the credential is protected on the
    # first hop and not the second. Fixing that needs TLS on fredhub, which is
    # a separate piece of work.
    ai = {
      legacy = [
        "ai.sdrhub.lan"
        "ai.sdrhub.local"
      ];
      vhost.locations."/".proxyPass = "http://192.168.31.14:8889";
    };

    # Jellyfin on fredhub. Same login exposure, and the same second-hop
    # caveat as ai above.
    jellyfin = {
      legacy = [
        "jellyfin.sdrhub.lan"
        "jellyfin.sdrhub.local"
      ];
      vhost.locations."/".proxyPass = "http://192.168.31.14:8096";
    };

    # degoog. Search queries are worth protecting on their own, and the
    # container carries a settings password.
    search = {
      legacy = [
        "search.sdrhub.lan"
        "search.sdrhub.local"
      ];
      vhost.locations."/".proxyPass = "http://127.0.0.1:4444";
    };

    # Karma alert dashboard. Bound to loopback by
    # modules/monitoring/master/karma.nix and reached only through here, so it
    # needs no firewall port of its own. The port is read from the service
    # definition rather than hardcoded.
    #
    # Karma pushes live alert updates over a websocket, hence the upgrade
    # headers (the $connection_upgrade map is defined in appendHttpConfig).
    karma = {
      legacy = [
        "karma.sdrhub.lan"
        "karma.sdrhub.local"
      ];
      vhost.locations."/" = {
        proxyPass = "http://127.0.0.1:${toString config.services.karma.settings.listen.port}";
        extraConfig = ''
          proxy_http_version 1.1;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection $connection_upgrade;
        '';
      };
    };

    # Clipboard payloads are whatever happened to be on a clipboard, so the
    # default 1m body limit is far too small once images are in play. The
    # upstream is loopback-only, so this vhost is the only way in.
    clipboard = {
      legacy = [
        "clipboard.sdrhub.lan"
        "clipboard.sdrhub.local"
      ];
      vhost.locations."/" = {
        proxyPass = "http://127.0.0.1:5033";
        extraConfig = ''
          client_max_body_size 512m;

          # Stream to the upstream instead of buffering. Auth happens in
          # SyncClipboard, not nginx, so with the default
          # proxy_request_buffering on any LAN client could push 512m of
          # body to disk before ever being told 401. Streaming lets the
          # upstream reject it immediately, and client_body_timeout bounds
          # a slow trickle (proxy_read_timeout only covers the response).
          proxy_request_buffering off;
          client_body_timeout 60s;
          proxy_read_timeout 300s;
        '';
      };
    };
  };

  # The serving half.
  tlsVirtualHosts = lib.mapAttrs' (
    name: def:
    lib.nameValuePair "${name}.${internalDomain}" (
      def.vhost
      // {
        forceSSL = true;
        useACMEHost = internalDomain;
      }
    )
  ) migratedVhosts;

  # The compatibility half: the old plaintext names, now doing nothing but
  # pointing at the new ones.
  #
  # 308, not 301. A 301 permits a client to replay the request as a GET, and
  # historically most do; 308 requires the method and body to be preserved.
  # That is irrelevant for the browser-facing vhosts and load-bearing for
  # clipboard, whose clients PUT and POST -- a 301 there would silently
  # degrade a clipboard upload into a GET.
  #
  # An explicit `return` rather than nginx's `globalRedirect`, which emits the
  # scheme of the *redirecting* server block. On these plaintext blocks that
  # yields `http://<new name>`, which the TLS vhost then has to bounce a
  # second time -- two round trips, the first still in the clear, which is
  # most of what this change exists to stop.
  legacyRedirectVirtualHosts = lib.mapAttrs' (
    name: def:
    lib.nameValuePair (lib.head def.legacy) (
      {
        serverAliases = lib.tail def.legacy;
        locations."/".return = "308 https://${name}.${internalDomain}$request_uri";
      }
      // lib.optionalAttrs (def.legacyDefault or false) { default = true; }
    )
  ) migratedVhosts;

  # AdGuard rewrites for the TLS names. Every migrated vhost answers on this
  # host, so they all resolve to it.
  #
  # Deliberately derived from migratedVhosts rather than emitted as a third
  # TLD by mkRewrites over lanHosts. Most of lanHosts is not served by nginx
  # at all (acarshub, fredvps, nvrhub, ... are plain DNS convenience for
  # reaching other machines), and giving those names under internalDomain
  # would advertise names that resolve but have no vhost, landing them on the
  # catch-all.
  #
  # Note the shape differs from the `.lan` names on purpose: the `sdrhub`
  # label is dropped, because `int.fredsystems.org` already says which network
  # this is and a wildcard only covers a single label level.
  tlsRewrites = lib.mapAttrsToList (name: _: {
    enabled = true;
    domain = "${name}.${internalDomain}";
    answer = "192.168.31.20";
  }) migratedVhosts;
in
{
  imports = [
    ./hardware-configuration.nix
    ./acme.nix
    ../../../modules/secrets/sops.nix
    ../../../modules/services/adsb-docker-units.nix
    ../../../modules/monitoring/master
    ../../../modules/monitoring/agent
    ../../../modules/services/tailscale
    ../../../modules/hardware/usbfs.nix
    ./home-ip-drift.nix
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
        # nginx TLS, for the vhosts that have been migrated to the
        # int.fredsystems.org certificate. 80 stays open: the `.lan` vhosts
        # are still plaintext by design during the migration.
        443
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

            # TWO INDEPENDENT PROVIDERS, not one provider's two addresses.
            #
            # This is the fix for a total LAN external-DNS outage on 2026-08-16
            # (29 minutes) and an identical one on 2026-08-15 (8 minutes). Every
            # address here was Quad9, so one provider becoming unreachable left
            # unbound with no working upstream at all. Combined with
            # `forward-first = false` below there was no fallback, so unbound
            # answered SERVFAIL for every external name, AdGuard passed that
            # straight through to the LAN, and every service involved stayed
            # `active (running)` the whole time.
            #
            # unbound tracks round-trip time per upstream in its infra cache and
            # marks unresponsive servers down, so it fails over across these
            # without any further configuration.
            #
            # Both are each provider's MALWARE-FILTERING variant on purpose --
            # Quad9's dns11 and Cloudflare's `security` endpoint. Mixing a
            # filtering resolver with a non-filtering one would make blocking
            # depend on which upstream happened to win the RTT race, which is
            # the kind of difference nobody notices until it matters.
            #
            # One real behavioural difference to know about: 9.9.9.11 supports
            # EDNS Client Subnet (which is why that variant was chosen, and
            # AdGuard sets edns_client_subnet.enabled) whereas Cloudflare
            # strips ECS. CDN answers may be geolocated slightly less precisely
            # when Cloudflare serves the query. That is an acceptable trade for
            # not losing the LAN's DNS.
            #
            # Verified from sdrhub before committing: all four reachable on 853,
            # and all four complete a real DoT query with certificate validation
            # against the system CA bundle
            # (`kdig +tls +tls-ca +tls-hostname=<name> @<addr>`).
            forward-addr = [
              "9.9.9.11@853#dns11.quad9.net"
              "149.112.112.11@853#dns11.quad9.net"
              "1.1.1.2@853#security.cloudflare-dns.com"
              "1.0.0.2@853#security.cloudflare-dns.com"
            ];
            forward-tls-upstream = true;

            # Deliberately still false, and this is a decision rather than an
            # oversight.
            #
            # `forward-first = true` makes unbound fall back to ordinary
            # iterative resolution when a forwarded query SERVFAILs. That would
            # have kept the LAN up on both outage dates -- but it does it
            # silently over plaintext port 53, leaking every query with no
            # signal that it happened, which removes the entire reason DoT is
            # configured here.
            #
            # The mitigation chosen instead is redundancy (above) plus detection
            # (the DNS probes in modules/monitoring/master/blackbox.nix).
            # Revisit only if an outage is ever traced to outbound 853 being
            # blocked wholesale rather than to a single provider failing --
            # redundancy cannot help with that, and the probes are what would
            # tell the difference.
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

          rewrites = mkRewrites lanHosts ++ tlsRewrites;
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
        image = "amir20/dozzle:v10.7.2@sha256:01f9018ffdaa0ec523f9a91dea3eff65b25cdb5f0566ac6d5a2cb4cf591e35e9";

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
        image = "ghcr.io/sdr-enthusiasts/docker-adsb-ultrafeeder:latest-build-953@sha256:10d39707378e2518cc5b65c58a90bd54a90ce2638c79ea9a1bde69fe9202b8c8";

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
        image = "ghcr.io/sdr-enthusiasts/docker-acarshub:latest-build-1509@sha256:5a4967a1c5520bbcf796afa664a05344657b918c2b254626ba9fd7bcfbf7fcb2";

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
      # SYNCCLIPBOARD (clipboard sync + server-side history)
      ###############################################################
      {
        name = "syncclipboard";
        image = "jericx/syncclipboard-server:v3.2.0@sha256:3f2d9c6ce4fbefca769e40d79ed2cac2ad8fc3adf962c0599ba9176b502a3b6d";

        restart = "always";

        # Credentials only; the image's own appsettings.json supplies the
        # rest, including MaxSavedHistoryCount. The env vars take priority
        # over that file when both are non-empty, which is why the password
        # never has to appear in the Nix store.
        environmentFiles = [
          config.sops.secrets."docker/sdrhub/syncclipboard.env".path
        ];

        # Loopback-only. The server speaks plain HTTP and carries a password,
        # so it is reached exclusively through the nginx vhost below rather
        # than being published to the LAN. Same reasoning as karma/blackbox.
        ports = [
          "127.0.0.1:5033:5033"
        ];

        volumes = [
          "/opt/adsb/syncclipboard:/app/data"
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
      # New here, and safe to add in the same change that introduces the
      # first TLS vhost: it only touches TLS parameters (protocol floor,
      # cipher list, session cache, stapling), and until now this host
      # terminated no TLS at all, so there is nothing it can regress.
      recommendedTlsSettings = true;

      appendHttpConfig = ''
        map $http_upgrade $connection_upgrade {
          default upgrade;
          "" close;
        }
      '';

      virtualHosts =
        tlsVirtualHosts
        // legacyRedirectVirtualHosts
        // {
          # Explicit catch-all for unmatched SNI on 443.
          #
          # Without it nginx promotes whichever TLS server block sorts first
          # to be the implicit default_server, and hands that vhost's
          # certificate to clients asking for names we do not serve. That is
          # exactly the bug documented at length in
          # hosts/linux/fredvps/nginx.nix, where a typo'd domain ended up
          # being served acarshub.app's certificate.
          #
          # onlySSL rather than addSSL, unlike fredvps: the plaintext landing
          # page already claims default_server on port 80 and nginx rejects a
          # duplicate. This block therefore takes the 443 default only.
          "_" = {
            default = true;
            serverName = "_";
            onlySSL = true;
            sslCertificate = "${snakeoilCert}/cert.pem";
            sslCertificateKey = "${snakeoilCert}/key.pem";
            extraConfig = ''
              return 444;
            '';
          };
        };
    };
  };

  # The TLS vhost above and the certificate in ./acme.nix are joined only by a
  # bare string, and the nginx module does not check that the string resolves
  # to anything. Given a name it does not recognise it silently declares a
  # *new* certificate under it, which inherits `security.acme.defaults` and so
  # has no dnsProvider -- leaving a host that builds and deploys fine and then
  # fails issuance, with the TLS vhost serving nothing.
  #
  # Any real certificate for this domain must have a dnsProvider, since DNS-01
  # is the only challenge that can work for a name with no public address
  # record. Its absence therefore means exactly one thing: the two files have
  # drifted apart.
  assertions = [
    {
      assertion = config.security.acme.certs.${internalDomain}.dnsProvider != null;
      message = ''
        sdrhub: nginx uses useACMEHost = "${internalDomain}", but no certificate
        of that name declares a dnsProvider. Either `internalDomain` in
        configuration.nix or the `security.acme.certs.<name>` attribute in
        acme.nix was renamed without the other.
      '';
    }
  ];

  system.stateVersion = stateVersion;

  system.activationScripts.adsbDockerCompose = {
    text = ''
      # Ensure directory exists (does not touch contents if already there)
      install -d -m0755 -o fred -g users /opt/adsb
      install -d -m0755 -o fred -g users /opt/adsb/degoog
      # 0700, unlike its siblings: this one holds clipboard history, which
      # is whatever happened to be copied, passwords included. The image sets
      # no USER so the container runs as root and writes root-owned,
      # world-readable files; 0755 left them traversable by any local user.
      # Root ignores DAC, so tightening the directory does not affect it.
      install -d -m0700 -o fred -g users /opt/adsb/syncclipboard
    '';
    deps = [ ];
  };

  sops.secrets = {
    "docker/sdrhub/dozzle.env" = mkContainerSecret "dozzle";
    "docker/sdrhub/syncclipboard.env" = mkContainerSecret "syncclipboard";

    # Deliberately NOT mkContainerSecret. Both are declared but unconsumed:
    # the dozzle-agent container takes no environmentFiles (its secret is
    # "intentionally empty (no env vars required)"), and the airspy_adsb
    # container is commented out entirely. Attaching restartUnits to either
    # would name a container that does not read it, which is a claim the
    # config cannot honour. If airspy_adsb is uncommented, or dozzle-agent
    # ever gains real env vars, convert them then.
    "docker/sdrhub/dozzle-agent.env" = {
      format = "yaml";
    };

    "docker/sdrhub/airspy_adsb.env" = {
      format = "yaml";
    };

    "docker/sdrhub/ultrafeeder.env" = mkContainerSecret "ultrafeeder";

    "docker/sdrhub/dump978.env" = mkContainerSecret "dump978";

    "docker/sdrhub/adsbhub.env" = mkContainerSecret "adsbhub";

    "docker/sdrhub/fr24.env" = mkContainerSecret "fr24";

    "docker/sdrhub/piaware.env" = mkContainerSecret "piaware";

    "docker/sdrhub/planefinder.env" = mkContainerSecret "planefinder";

    "docker/sdrhub/planewatch.env" = mkContainerSecret "planewatch";

    "docker/sdrhub/radarvirtuel.env" = mkContainerSecret "radarvirtuel";

    "docker/sdrhub/rbfeeder.env" = mkContainerSecret "rbfeeder";

    "docker/sdrhub/opensky.env" = mkContainerSecret "opensky";

    "docker/sdrhub/sdrmap.env" = mkContainerSecret "sdrmap";

    # Shared by both acarshub and acarshubv4; each must pick up the change.
    "docker/sdrhub/acarshub.env" = mkContainerSecrets [
      "acarshub"
      "acarshubv4"
    ];

    "docker/sdrhub/acars_router.env" = mkContainerSecret "acars_router";

    "docker/sdrhub/acars2pos.env" = mkContainerSecret "acars2pos";
  };
}
