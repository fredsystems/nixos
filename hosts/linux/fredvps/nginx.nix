{ pkgs, ... }:
let
  # Self-signed throwaway cert for the catch-all default vhost below.
  # There's no real domain to get an ACME cert for "_" / unmatched SNI --
  # the point is just to stop leaking a *real* vhost's cert (acarshub.app)
  # to clients presenting a Host/SNI we don't recognize.
  snakeoilCert =
    pkgs.runCommand "nginx-default-snakeoil-cert" { nativeBuildInputs = [ pkgs.openssl ]; }
      ''
        mkdir -p "$out"
        openssl req -x509 -nodes -newkey rsa:2048 -days 36500 \
          -keyout "$out/key.pem" -out "$out/cert.pem" \
          -subj "/CN=invalid"
      '';

  # Per-server-block hardening, prepended to every vhost's extraConfig.
  #
  # This lives at the server level rather than in a location block because
  # most vhosts here are `globalRedirect` only and define no locations at all
  # -- a location-based rule would silently skip them, which is precisely the
  # set of vhosts a scanner enumerating our domains would hit first.
  hardenVhost = existing: ''
    # $blocked_probe is computed by the map in commonHttpConfig.
    if ($blocked_probe) {
      return 444;
    }

    # Burst absorbs a normal page's worth of parallel subresource requests;
    # nodelay serves them immediately rather than queueing, so the limit is
    # invisible to real users and only bites sustained automation.
    limit_req zone=general burst=60 nodelay;

    ${existing}
  '';
in
{
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  security.acme = {
    acceptTerms = true;
    defaults.email = "clausen.fred@me.com";
  };

  systemd.tmpfiles.rules = [
    "d /var/www 0755 root root -"
  ];

  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    # Rate-limit zones. Defined here so every vhost can share them; only the
    # vhosts that need one apply it, since `limit_req_zone` allocates shared
    # memory whether or not it is used.
    #
    # Sized from a week of real traffic: 1.3M requests in the current access
    # log, of which 38443 were exploit probes from 754 distinct addresses.
    # $binary_remote_addr is 4 bytes per IPv4 entry, so 10m holds on the order
    # of 160k addresses -- far more than the ~750 seen weekly, with headroom
    # for a distributed sweep.
    appendHttpConfig = ''
      # General browsing. 30r/s is roughly an order of magnitude above what a
      # human page load produces, so it only engages against automation.
      limit_req_zone $binary_remote_addr zone=general:10m rate=30r/s;

      # The flipaholics API. Its clients legitimately poll hard -- a single
      # address made 230 price_data calls in two days and several hold
      # long-running watchlist polls -- so this is deliberately generous. It
      # exists to bound a runaway client, not to shape normal use.
      limit_req_zone $binary_remote_addr zone=api:10m rate=20r/s;

      # 429 rather than the nginx default 503: 503 says "server is broken and
      # will be back", which invites retries and is what made the earlier 500s
      # self-perpetuating. 429 says "you are going too fast", which
      # well-behaved clients back off from and which fail2ban can key on.
      limit_req_status 429;

      # Log at warn so the fail2ban nginx-limit-req jail below has something
      # to match; nginx logs limiting at "error" by default, which buries it
      # among real faults.
      limit_req_log_level warn;
    '';

    # Applied to every server block, including the globalRedirect-only vhosts
    # which define no locations of their own.
    #
    # Nothing here is currently leaking -- probes for /.env, /.git/config,
    # /.aws/credentials and friends were verified by hand and all return the
    # React SPA's index.html with no secret material in it. The problem is
    # that returning 200 to /.env makes the access log indistinguishable from
    # a real compromise, and it encourages scanners to keep going: 1558
    # requests for /.env and 2109 for a WordPress filemanager exploit in a
    # single week.
    #
    # 444 (nginx's "close without response") rather than 403: a scanner
    # learns nothing from a dropped connection, and it costs us no response
    # body.
    #
    # ACME is unaffected. Certbot's challenge location is
    # `location ^~ /.well-known/acme-challenge/`, and nginx evaluates a `^~`
    # prefix match ahead of any regex location, so renewal never reaches the
    # rule below. Verified against the generated nginx.conf.
    commonHttpConfig = ''
      map $request_uri $blocked_probe {
        default 0;

        # Dotfile directories that only ever appear in credential-theft
        # scans: .env, .git, .aws, .ssh, .svn, .DS_Store and friends. The
        # well-known exemption keeps ACME and security.txt working.
        "~*^/\.(?!well-known/)"                     1;

        # PHP. Nothing on this host runs PHP, so any request for it is a
        # probe by definition.
        "~*\.php(\?|$|/)"                           1;

        # WordPress. Likewise not deployed anywhere here.
        "~*^/(wp-admin|wp-content|wp-includes|wordpress|xmlrpc)"  1;

        # Miscellaneous scanner staples.
        "~*^/(phpmyadmin|pma|adminer|cgi-bin|vendor/phpunit|_profiler)"  1;
        "~*^/(config|configuration|settings|credentials|secrets)\.(json|ya?ml|xml|bak|old)$"  1;
      }
    '';

    # Every vhost gets the probe guard and the general rate limit, applied by
    # mapAttrs below rather than repeated 15 times. Doing it structurally
    # means a vhost added later is protected by default instead of depending
    # on whoever adds it remembering.
    virtualHosts =
      builtins.mapAttrs (_: vhost: vhost // { extraConfig = hardenVhost (vhost.extraConfig or ""); })
        {
          "onemorefoot.com" = {
            forceSSL = true;
            enableACME = true;
            serverAliases = [ "www.onemorefoot.com" ];

            globalRedirect = "fredclausen.com";
          };

          "atcfreq.com" = {
            forceSSL = true;
            enableACME = true;
            serverAliases = [ "www.atcfreq.com" ];

            globalRedirect = "fredclausen.com";
          };

          "epicspam.com" = {
            forceSSL = true;
            enableACME = true;
            serverAliases = [ "www.epicspam.com" ];

            globalRedirect = "fredclausen.com";
          };

          "politicalpileon.com" = {
            forceSSL = true;
            enableACME = true;
            serverAliases = [ "www.politicalpileon.com" ];

            globalRedirect = "fredclausen.com";
          };

          "therightradio.com" = {
            forceSSL = true;
            enableACME = true;
            serverAliases = [ "www.therightradio.com" ];

            globalRedirect = "fredclausen.com";
          };

          "sdrdockerconfig.com" = {
            forceSSL = true;
            enableACME = true;
            serverAliases = [ "www.sdrdockerconfig.com" ];

            globalRedirect = "fredclausen.com";
          };

          "adsb-pi.com" = {
            forceSSL = true;
            enableACME = true;
            serverAliases = [ "www.adsb-pi.com" ];

            globalRedirect = "fredclausen.com";
          };

          "freminal.com" = {
            forceSSL = true;
            enableACME = true;
            serverAliases = [ "www.freminal.com" ];

            globalRedirect = "fredclausen.com";
          };

          "sdr-e.org" = {
            forceSSL = true;
            enableACME = true;
            serverAliases = [ "www.sdr-e.org" ];

            globalRedirect = "github.com/sdr-enthusiasts";
          };

          "sdr-enthusiasts.org" = {
            forceSSL = true;
            enableACME = true;
            serverAliases = [ "www.sdr-enthusiasts.org" ];

            globalRedirect = "github.com/sdr-enthusiasts";
          };

          "fredclausen.com" = {
            forceSSL = true;
            enableACME = true;
            serverAliases = [ "www.fredclausen.com" ];

            locations = {
              "/" = {
                proxyPass = "http://127.0.0.1:4200/";
              };

              "/cider-v3.1.8-linux-x64.AppImage" = {
                root = "/var/www";
                # extraConfig = ''
                #   add_header Content-Type application/octet-stream;
                #   add_header Content-Disposition "attachment; filename=cider-v3.1.8-linux-x64.AppImage";
                # '';
              };

              "/acarshub/" = {
                proxyPass = "http://127.0.0.1:8085/";
                proxyWebsockets = true;
                extraConfig = ''
                  proxy_redirect / /acarshub/;
                  proxy_set_header X-Forwarded-Prefix /acarshub;
                '';
              };

              "/imageapi/" = {
                proxyPass = "http://127.0.0.1:3001/";
                proxyWebsockets = true;
                extraConfig = ''
                  proxy_redirect / /imageapi/;
                  proxy_set_header X-Forwarded-Prefix /imageapi;
                '';
              };

              "/tar1090/" = {
                proxyPass = "http://127.0.0.1:8081/";
                extraConfig = ''
                  proxy_redirect / /tar1090/;
                  proxy_set_header X-Forwarded-Prefix /tar1090;
                '';
              };
            };
          };

          "acarshub.app" = {
            forceSSL = true;
            enableACME = true;
            serverAliases = [ "www.acarshub.app" ];

            locations."/" = {
              proxyPass = "http://127.0.0.1:8085/";
              proxyWebsockets = true;
            };
          };

          "acarshub.com" = {
            forceSSL = true;
            enableACME = true;
            serverAliases = [ "www.acarshub.com" ];
            globalRedirect = "acarshub.app";
          };

          "flipaholics.pro" = {
            forceSSL = true;
            enableACME = true;
            serverAliases = [ "www.flipaholics.pro" ];

            locations."/" = {
              proxyPass = "http://127.0.0.1:8078/";
            };

            # The busiest vhost by a wide margin, and the one that attracts real
            # traffic rather than only scanners, so its API gets the looser zone.
            # Clients poll /api/price_data and /api/watchlist hard by design --
            # one address made 230 price_data calls in two days -- and the general
            # 30r/s zone would eventually clip a legitimate burst.
            #
            # The higher burst (100) matters more than the rate here: watchlist
            # clients fan out many requests at once and then go quiet, which is a
            # burst pattern rather than a sustained one.
            locations."/api/" = {
              proxyPass = "http://127.0.0.1:8078/api/";
              extraConfig = ''
                limit_req zone=api burst=100 nodelay;
              '';
            };
          };

          # Explicit catch-all default: without this, nginx (and the NixOS
          # module) fall back to whichever vhost happens to sort first
          # alphabetically (attrsets are always key-sorted) as the *implicit*
          # default_server for any Host/SNI that doesn't match a declared
          # vhost -- serving that vhost's content AND its TLS cert to totally
          # unrelated domains. That's exactly how a typo'd/unlisted domain
          # (flipaholic.pro) ended up being served acarshub.app's cert. This
          # block makes "no match" fail closed instead of silently leaking
          # whatever happens to be alphabetically first.
          "_" = {
            default = true;
            serverName = "_";
            # addSSL (not forceSSL/onlySSL): serve the catch-all on *both*
            # plain :80 and :443 as default_server, using the throwaway
            # self-signed cert above -- forceSSL/enableACME would need a
            # real domain to issue for, and onlySSL would drop the :80
            # default, leaving port 80's implicit-default bug unfixed.
            addSSL = true;
            sslCertificate = "${snakeoilCert}/cert.pem";
            sslCertificateKey = "${snakeoilCert}/key.pem";
            extraConfig = ''
              return 444;
            '';
          };
        };
  };
}
