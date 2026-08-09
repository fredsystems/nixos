{
  lib,
  pkgs,
  stateVersion,
  config,
  ...
}:
let
  inherit (import ../../../modules/services/mk-container-secret.nix)
    mkContainerSecret
    ;

  # Bind addresses for container port publishing.
  #
  # Docker's `-p` defaults to 0.0.0.0, and its DNAT rules are installed in the
  # DOCKER chain, which nftables/iptables evaluates BEFORE nixos-fw. The result
  # was that `networking.firewall.allowedTCPPorts` described a machine that did
  # not exist: the firewall listed 80/443/2269/8078, while every container port
  # -- tar1090, acarshub, imageapi, fredsite, the dozzle agent, and the whole
  # ADS-B feed range -- was in fact reachable from the public internet.
  #
  # That was not theoretical. A confirmed Tor exit node (192.42.116.47,
  # AS215125 "Church of Cyberology") held a 4.2-hour connection to :30005 and
  # pulled 26 MB of Beast data, and a Surfshark VPN endpoint
  # (178.255.41.198) was simultaneously pulling :30005 and browsing the
  # tar1090 UI on :8081. Neither appeared in nginx's access log, because
  # neither went through nginx.
  #
  # Publishing on an explicit address is the fix. nginx reaches the web
  # backends over the loopback, and sdrhub reaches the feed listeners over
  # Tailscale, so nothing legitimate needs a public bind.
  localhost = "127.0.0.1";

  # fredvps's stable Tailscale address. Feed ports bind here so sdrhub can
  # reach them while the public internet cannot. Hardcoded rather than
  # discovered because container `-p` flags are rendered at build time, long
  # before tailscaled has an address to report.
  tailscaleIP = "100.82.147.29";
in
{
  imports = [
    ./hardware-configuration.nix
    ../../../profiles/adsb-hub.nix
    ../../../modules/services/tailscale
    ../../../modules/services/python-venv-app.nix
    ../../../modules/system/docker-user-firewall.nix
    ./nginx.nix
    ./discord-backup.nix
    ./imageapi-metrics.nix
  ];

  # Tailscale MagicDNS name — fill in your tailnet name, e.g. "fredvps.tail1234.ts.net"
  # Run `tailscale status` after first deploy to confirm the assigned name.
  deployment = {
    scrapeAddress = "fredvps.tailc21fc7.ts.net";

    # The only node in this fleet with a public interface. Everything else
    # sits behind NAT, which is why the monitoring exporters bind 0.0.0.0 and
    # open their own firewall ports by default -- harmless on the LAN, but on
    # this host it published node_exporter (3021 lines of host metrics) and
    # cAdvisor (per-container stats, including every container name)
    # unauthenticated to the internet. Prometheus already scrapes this node
    # over Tailscale, so binding the tailnet address costs nothing.
    internetFacing = true;
    tailscaleAddress = tailscaleIP;
  };

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

  # Filter backing the nginx-probe jail above. Matches the 444 that the
  # $blocked_probe map in nginx.nix returns for credential-theft and
  # WordPress/PHP scans.
  #
  # 444 is nginx's "close the connection without a response", which never
  # reaches the wire as a status code -- it only ever appears in our own
  # access log, written by our own rule. That makes it an unambiguous marker
  # for "this request was a probe", unlike 404 or 403 which legitimate traffic
  # also produces here in volume.
  environment.etc."fail2ban/filter.d/nginx-probe.conf".text = ''
    [Definition]
    # `.*` between the host and the request rather than an explicit
    # `\S+ \S+ \[timestamp\]`: fail2ban extracts the timestamp with
    # datepattern and hands the failregex a line with that section already
    # substituted, so a regex that tries to match the literal
    # "- - [09/Aug/2026:01:34:08 -0600]" never fires. That was verified the
    # hard way -- the stricter pattern matched 0 of 94 real 444 lines.
    #
    # The trailing \s keeps this anchored to the status field so it cannot
    # match a 444 appearing anywhere else in the line, e.g. in a URL or a
    # user agent.
    failregex = ^<HOST> .* "[A-Z]+ [^"]*" 444\s
    ignoreregex =
    datepattern = ^[^\[]*\[({DATE})
                  {^LN-BEG}
  '';

  # Backstop for the Docker/nixos-fw gap described at the top of this file.
  # Every container port is now published on an explicit bind address, so in
  # the current configuration this chain should never actually drop a packet.
  # It exists so that the next container added here fails closed if its port
  # mapping omits the bind address, instead of silently reappearing on the
  # public internet the way :30005 and :7007 did.
  dockerUserFirewall = {
    enable = true;
    externalInterface = "enp1s0";
    # Deliberately empty: nothing published by a container on this host is
    # meant to be publicly reachable. nginx is not a container and is
    # unaffected -- it binds the host directly on 80/443 via nixos-fw.
    allowedTCPPorts = [ ];
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
    "docker/fredvps/tar1090.env" = mkContainerSecret "tar1090";

    "docker/fredvps/acars_router.env" = mkContainerSecret "acars_router";

    "docker/fredvps/acarshub.env" = mkContainerSecret "acarshub";

    "docker/fredvps/fredsite.env" = mkContainerSecret "fredsite";

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

      # Never ban ourselves off the box.
      #
      # Loopback and the tailnet, so a misfiring filter cannot cut the
      # Tailscale management path or ban sdrhub's monitoring, which probes
      # every vhost on a schedule.
      #
      # 73.26.160.99 is the home Comcast address. It is listed because a live
      # test of the nginx-probe jail banned it within seconds -- three
      # deliberate requests to /.env from a workstation behind that address
      # were enough. The ADS-B feeds themselves now run over Tailscale and
      # were unaffected, but a ban still blocks ordinary HTTPS access to every
      # vhost from home, which is a self-inflicted outage for the exact
      # behaviour someone debugging this host is most likely to produce.
      #
      # This is a dynamic address, so it will eventually go stale. That fails
      # safe: the entry stops matching and the jail simply applies normally.
      ignoreIP = [
        "127.0.0.1/8"
        "::1"
        "100.64.0.0/10"
        "73.26.160.99"
      ];

      jails = {
        sshd.settings = {
          enabled = true;
          port = "2269";
          filter = "sshd";
          maxretry = 3;
        };

        # Exploit probes, keyed on the 444s produced by the nginx map.
        #
        # The stock nginx-botsearch filter is deliberately NOT used: its
        # failregex matches status 404, and on this host 404 is overwhelmingly
        # legitimate. Real clients generate thousands of them against
        # /api/price_data for items that are simply not in the database --
        # 105.159.200.113 alone produced hundreds. Banning on 404 here would
        # ban customers. 444 is only ever emitted by our own probe rule, so it
        # is an exact signal with no false-positive surface.
        nginx-probe.settings = {
          enabled = true;
          filter = "nginx-probe";
          port = "http,https";
          logpath = "/var/log/nginx/access.log";
          backend = "auto";
          maxretry = 3;
          findtime = "10m";
        };

        # Clients that sustain enough traffic to trip limit_req. Tolerant on
        # purpose: tripping the limiter once is a burst, doing it ten times in
        # ten minutes is a runaway or a scraper.
        nginx-limit-req.settings = {
          enabled = true;
          filter = "nginx-limit-req";
          port = "http,https";
          logpath = "/var/log/nginx/error.log";
          backend = "auto";
          maxretry = 10;
          findtime = "10m";
        };

        # Malformed requests -- protocol garbage and oversized headers. 2241
        # of these in the current log.
        nginx-bad-request.settings = {
          enabled = true;
          filter = "nginx-bad-request";
          port = "http,https";
          logpath = "/var/log/nginx/access.log";
          backend = "auto";
          maxretry = 10;
          findtime = "10m";
        };
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
        # --no-access-log: uvicorn's per-request log was 248780 of this unit's
        # 373819 journal lines over two days (67%), making it the single
        # largest log producer on the host by a wide margin. It is also pure
        # duplication -- nginx already records every one of these requests in
        # /var/log/nginx/access.log (1.3M entries in the current file), and
        # `ss` confirms nothing reaches :8078 except via the flipaholics.pro
        # proxy_pass, so dropping it loses no coverage. Revisit if :8078 is
        # ever exposed directly, since then nginx would no longer see
        # everything.
        execStart = "$VENV/bin/uvicorn app.main:app --host 0.0.0.0 --port 8078 --workers 2 --no-access-log";
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

        # Proxied by nginx at fredclausen.com/. Loopback only.
        ports = [ "${localhost}:4200:80" ];
      }
      ###############################################################
      # DOZZLE AGENT
      ###############################################################
      # Tailscale-only. This agent mounts docker.sock, and Dozzle's agent
      # certificate is shared across all Dozzle images rather than being a
      # per-deployment secret, so a publicly reachable :7007 let anyone point
      # their own Dozzle at this host and read every container's logs --
      # including anything secret-bearing that gets logged. sdrhub is the only
      # consumer and is on the tailnet.
      (import ../../../modules/services/mk-dozzle-agent.nix {
        port = "${tailscaleIP}:7007:7007";
      })

      ###############################################################
      # IMAGE API
      ###############################################################
      {
        name = "imageapi";
        image = "ghcr.io/sdr-enthusiasts/sdre-image-api:latest-build-7@sha256:38df445fe37101648032e849a477ee3221ce8517cebd72983e21d9e1ba8dfbff";

        volumes = [
          "/opt/adsb/imageapi/data:/opt/api"
          "${config.sops.secrets.github_api.path}:/opt/api/sdre-e-updater.2024-02-05.private-key.pem:ro"
        ];

        # Proxied by nginx at /imageapi/. Loopback only.
        ports = [ "${localhost}:3001:3000" ];
      }

      ###############################################################
      # tar1090
      ###############################################################
      {
        name = "tar1090";
        image = "ghcr.io/sdr-enthusiasts/docker-tar1090:latest-build-1470@sha256:7ae0793a00adb97999dfd676831ab113d9de026a95a139b005f8942bd02ca7af";

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
          # Web UI: proxied at /tar1090/, so loopback is all nginx needs.
          "${localhost}:8081:80"

          # 30004 (beast_in) and 12000 (sbs_out_jaero) are the only feed ports
          # sdrhub's ultrafeeder actually dials, so they move to Tailscale.
          "${tailscaleIP}:30004:30004"
          "${tailscaleIP}:12000:12000"

          # 30005 is readsb's Beast *output*. It had no authorised consumer --
          # the only two clients were the Tor exit and the Surfshark endpoint
          # described above, both of which had simply found an open port.
          # Bound to Tailscale rather than deleted so it stays available to the
          # fleet, since removing the mapping outright would make a future
          # legitimate consumer look like a container misconfiguration.
          "${tailscaleIP}:30005:30005"

          # 30002 (raw out), 30003 (SBS/BaseStation out) and 30047 have no
          # observed clients at all. Same reasoning: keep the mapping, drop
          # the public exposure.
          "${tailscaleIP}:30002:30002"
          "${tailscaleIP}:30003:30003"
          "${tailscaleIP}:30047:30047"
        ];
      }

      ###############################################################
      # acars_router
      ###############################################################
      {
        name = "acars_router";
        image = "ghcr.io/sdr-enthusiasts/acars_router:latest-build-587@sha256:de236bc97c84e34679d2d0086524d9ebe2dc2252ed47799916a04e19578e4a67";

        environmentFiles = [
          config.sops.secrets."docker/fredvps/acars_router.env".path
        ];

        ports = [
          # sdrhub's acars_router pushes ACARS/VDLM2/HFDL into these three.
          # They are the only feed listeners with a real client, and that
          # client is on the tailnet.
          #
          # These were also the noisiest public ports: 1311 connection
          # attempts over seven days from 183 unique addresses on 5555 alone,
          # 297 of which reset immediately -- port sweeps, not feeders. Only
          # sdrhub ever held an established connection.
          "${tailscaleIP}:5550:5550"
          "${tailscaleIP}:5555:5555"
          "${tailscaleIP}:5556:5556"

          # Secondary listeners with no observed client on this host.
          "${tailscaleIP}:15550:15550"
          "${tailscaleIP}:15555:15555"
          "${tailscaleIP}:15556:15556"
          "${tailscaleIP}:35556:35556"
        ];
      }

      ###############################################################
      # ACARS Hub
      ###############################################################
      {
        name = "acarshub";
        image = "ghcr.io/sdr-enthusiasts/docker-acarshub:latest-build-1506@sha256:1ae9bb712fb3cbbc812da354431961812215306810675707277a319b07d52a91";

        environmentFiles = [
          config.sops.secrets."docker/fredvps/acarshub.env".path
        ];

        volumes = [
          "/opt/adsb/acarshub:/run/acars"
        ];

        ports = [
          # 8085 is proxied by nginx at /acarshub/ and at acarshub.app.
          # 8888 is the backend API, which the UI reaches in-container; it
          # had no external client and was answering unauthenticated version
          # banners to anyone who asked.
          "${localhost}:8085:80"
          "${localhost}:8888:8888"
        ];
      }
    ];
  };
}
