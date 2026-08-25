{
  config,
  stateVersion,
  lib,
  ...
}:
let
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
  #                  server block's name, tail its serverAliases. An EMPTY list
  #                  means no plaintext block is generated at all -- for a
  #                  service that never had a `.lan` name to be compatible with.
  #   legacyDefault  make the plaintext block port 80's default_server.
  #   vhost          the serving configuration; gains forceSSL + useACMEHost.
  #
  # REACHING adguard AND grafana WHEN DNS IS BROKEN
  #
  # Those two entries have `legacy = [ ]`, bind loopback, and have had their
  # firewall openings removed, so a name under internalDomain is their only
  # entry point -- and that name is answered by an AdGuard rewrite. During the
  # DNS fault this host's monitoring exists to catch, the AdGuard admin UI is
  # therefore unreachable by the very mechanism that is broken, and Grafana with
  # it. That is a real circularity, so the escape hatch is written down here
  # rather than rediscovered under pressure.
  #
  # SSH still works: it needs no name resolution and no nginx. Forward the
  # loopback ports and use 127.0.0.1 in the browser.
  #
  #   ssh -N -L 3003:127.0.0.1:3003 -L 3333:127.0.0.1:3333 192.168.31.20
  #
  # then http://127.0.0.1:3003/ for AdGuard and http://127.0.0.1:3333/ for
  # Grafana. Plaintext is fine: the only wire is the SSH tunnel. Both ports are
  # the ones the vhosts below read out of the service definitions, so if either
  # is retuned this command needs the same edit.
  #
  # Note Grafana's `root_url` is the TLS name, so it will emit absolute links
  # back to grafana.int.fredsystems.org that do not resolve. Log in and use the
  # UI; do not follow redirects out of it. AdGuard has no such problem.
  #
  # Tailscale is the other route in, and is the one to use from off the LAN. Use
  # the tailnet IP (`ssh 100.x.y.z`) rather than the MagicDNS name unless the
  # client is running tailscaled itself: the `tailc21fc7.ts.net` forward-zone in
  # unbound below is only reached THROUGH AdGuard, so it is broken by the same
  # fault. A Tailscale client resolves MagicDNS against its own local
  # 100.100.100.100 and is unaffected; anything else is not.
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

          # The landing page's repository jump box reads this.
          #
          # github-ci-exporter runs on this same host (it comes in with
          # ../../../modules/monitoring/master) bound to loopback, because it
          # holds a GitHub token. That posture is unchanged here: this is an
          # *exact-match* location, so it exposes precisely one read-only
          # JSON document and nothing else on the exporter. A prefix match
          # would publish /metrics -- which names every repository, workflow
          # and open PR -- to anything that can reach this vhost.
          #
          # An exact-match location also wins over the `/` static root above
          # regardless of ordering, so this cannot be shadowed by a file that
          # later lands in ./html.
          #
          # Proxying rather than having the page call api.github.com directly
          # keeps the fleet to one GitHub scraper and one token: the exporter
          # already enumerates these repositories every five minutes, and its
          # ETag cache means the index costs no extra API calls. A browser
          # doing it would burn the unauthenticated 60/hour budget, shared
          # across every device on the LAN, on ~350 paginated repositories.
          #
          # The listen address is read from the service definition rather than
          # hardcoded, the same way the karma and grafana vhosts do it, so the
          # proxy target cannot drift out of sync with the server it proxies.
          "= /repos.json" = {
            proxyPass = "http://${config.services.github-ci-exporter.listen}/repos.json";
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

    # AdGuard Home's admin UI. Bound to loopback by the services.adguardhome
    # block above, which also drops the firewall opening it used to have.
    #
    # No `legacy` names, same reasoning as grafana: it was only ever reached as
    # http://192.168.31.20:3000/, an address and port rather than a name, so
    # there is no `.lan` vhost to preserve and inventing one would mean creating
    # a plaintext entry point for the LAN's DNS control plane.
    #
    # The port is read from the service definition rather than hardcoded, so the
    # proxy target cannot drift away from the bind.
    adguard = {
      legacy = [ ];
      vhost.locations."/" = {
        proxyPass = "http://127.0.0.1:${toString config.services.adguardhome.port}";
        extraConfig = ''
          proxy_http_version 1.1;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection $connection_upgrade;
        '';
      };
    };

    # Grafana. Bound to loopback by modules/monitoring/master/grafana.nix, which
    # also drops the firewall opening it used to need, so this vhost is now the
    # only way in.
    #
    # No `legacy` names, unlike every other entry here. Grafana was never
    # reached by hostname -- it was http://sdrhub.lan:3333/, a port rather than
    # a name -- so there is no `.lan` vhost to preserve and inventing one would
    # mean creating a fresh plaintext entry point for the one service on this
    # host that carries admin credentials. The old URL stops working, which is
    # the point; the landing page link is updated to match.
    #
    # The port is read from the service definition rather than hardcoded, the
    # same way the karma vhost does it, so the proxy target cannot drift out of
    # sync with the server it proxies to.
    #
    # Grafana Live pushes dashboard updates over a websocket on /api/live/ws,
    # hence the upgrade headers (the $connection_upgrade map is defined in
    # appendHttpConfig).
    grafana = {
      legacy = [ ];
      vhost.locations."/" = {
        proxyPass = "http://127.0.0.1:${toString config.services.grafana.settings.server.http_port}";
        extraConfig = ''
          proxy_http_version 1.1;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection $connection_upgrade;
        '';
      };
    };

    # Prometheus.
    #
    # UNLIKE grafana and adguard above, this does NOT come with the service
    # being moved to loopback and its firewall port dropped. Port 9090 stays
    # open on the LAN, because daytona remote-writes to
    # http://192.168.31.20:9090/api/v1/write
    # (hosts/linux/daytona/configuration.nix) -- a cross-host write that a
    # loopback bind would break. So this vhost is an ADDITIONAL, encrypted way
    # in, not a replacement for the plaintext port. Anything reachable on the
    # LAN can still speak to :9090 directly.
    #
    # `legacy = [ ]`, same reasoning as grafana and adguard: Prometheus was
    # only ever reached as http://192.168.31.20:9090/, an address and a port
    # rather than a name, so there is no `.lan` vhost to preserve.
    #
    # basicAuth, which no other vhost on this host uses. Prometheus ships no
    # authentication whatsoever, and `--web.enable-admin-api` is set in
    # modules/monitoring/master/prometheus.nix, so an unauthenticated TLS name
    # would be a second route to /api/v1/admin/tsdb/delete_series. Grafana and
    # AdGuard both have their own logins and need no such wrapper.
    #
    # This is emphatically NOT a claim that Prometheus is now protected: the
    # open :9090 above is the honest hole, and basic auth here only ensures
    # the new name is not a *further* one. Closing the hole means repointing
    # daytona's remote-write at this vhost (with credentials) and then binding
    # Prometheus to loopback, which is a separate change.
    #
    # basicAuthFile rather than basicAuth: the latter takes a plaintext
    # attrset and renders it into the world-readable Nix store, which is the
    # same defect as the old hardcoded grafana secret_key. The file is a
    # bcrypt htpasswd from sops, owned by nginx.
    prometheus = {
      legacy = [ ];
      vhost = {
        basicAuthFile = config.sops.secrets."monitoring/prometheus_htpasswd".path;

        locations."/" = {
          # 127.0.0.1 rather than the LAN address: nginx and Prometheus are on
          # the same host, so there is no reason to leave the proxy hop on the
          # wire. The port is read from the service definition so the target
          # cannot drift from the bind.
          proxyPass = "http://127.0.0.1:${toString config.services.prometheus.port}";
        };
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

    # Synology DSM on the RackStation, at 192.168.31.16 (the same host
    # modules/data/nas-mounts.nix mounts /volume1/* from).
    #
    # The landing page used to link to http://192.168.31.20/rackstation -- a
    # path nginx on THIS host has never served, so the link 404'd here without
    # ever reaching the NAS.
    #
    # No `legacy` names, same reasoning as adguard and grafana: the old link was
    # an address and a path rather than a name, so there is no `.lan` vhost to
    # preserve, and inventing one would mean creating a plaintext entry point
    # for the machine that stores everything.
    #
    # WHY THE UPSTREAM IS https ON 5001 RATHER THAN http ON 5000
    #
    # DSM's login is the NAS's admin credential. Proxying to :5000 would put it
    # on the LAN in cleartext on the sdrhub -> NAS hop while the browser showed
    # a padlock -- precisely the defect that moved ai and jellyfin off this host
    # (see externalTlsHosts below and hosts/linux/fredhub/nginx.nix).
    #
    # There the fix was to remove the hop. That is not available here: DSM is not
    # managed by this flake, so terminating TLS on the NAS would mean a
    # hand-made reverse-proxy entry and a certificate maintained outside this
    # repository, and until that was done by hand the name would serve a cert
    # error. Encrypting the hop needs nothing on the NAS, because DSM already
    # listens on 5001.
    #
    # It also keeps DSM's absolute self-links on https, since the connection DSM
    # sees is https. Talking to :5000 would have it emit http:// URLs back to a
    # forceSSL vhost.
    #
    # WHAT THIS DOES NOT ACHIEVE
    #
    # DSM presents Synology's stock certificate (CN=synology.com, issuer
    # "Synology Inc. CA"), which chains to nothing nginx trusts. So this hop is
    # encrypted but NOT authenticated: it stops a passive listener on the LAN,
    # not an active machine-in-the-middle able to impersonate the NAS to nginx.
    #
    # Closing that gap needs a certificate nginx can actually check, which means
    # either vendoring Synology's CA into this repo -- and re-vendoring it every
    # time DSM regenerates -- or issuing a real certificate on the NAS. The
    # latter is the real fix and is DSM-side work; this is deliberately the
    # version that is strictly better than what it replaces with no manual step.
    #
    # The browser is unaffected by any of that. It validates only the wildcard
    # this vhost serves, so nas.int.fredsystems.org shows no warning even though
    # https://192.168.31.16:5001/ directly does.
    nas = {
      legacy = [ ];
      vhost.locations."/" = {
        proxyPass = "https://192.168.31.16:5001";
        extraConfig = ''
          # nginx's default, written out because this is a security posture and
          # not an accident: see WHAT THIS DOES NOT ACHIEVE above. Turning it on
          # without also supplying a trusted certificate would break the vhost
          # entirely rather than harden it.
          proxy_ssl_verify off;

          # DSM pushes desktop notifications, File Station transfer progress and
          # the Container Manager terminal over websockets. recommendedProxySettings
          # sets `Connection ""` at http level, so the upgrade has to be
          # re-established per location ($connection_upgrade lives in
          # appendHttpConfig).
          proxy_http_version 1.1;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection $connection_upgrade;

          # File Station uploads are whole files, so there is no sensible
          # ceiling to pick -- and the 1m default would reject nearly all of
          # them with a 413 that DSM surfaces as a generic upload failure.
          client_max_body_size 0;

          # Stream to DSM rather than spooling a multi-gigabyte upload into
          # nginx's temp directory in full before the NAS sees a byte.
          proxy_request_buffering off;

          # The defaults are 60s. A large transfer, a package install or a
          # long-running DSM task legitimately outlasts that and would be cut
          # off with a 504.
          proxy_read_timeout 600s;
          proxy_send_timeout 600s;
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
  #
  # WHAT THE REDIRECT DOES NOT FIX, FOR clipboard SPECIFICALLY
  #
  # A 308 only protects a client that has not sent anything yet. SyncClipboard
  # sends its HTTP Basic header preemptively rather than waiting for a 401, so a
  # client still configured with http://clipboard.sdrhub.lan puts the credential
  # on the wire in cleartext and only then reads the redirect. For that client
  # this compatibility layer removes nothing; it just makes the second attempt
  # encrypted.
  #
  # Two consequences, and neither is fixed by code in this file:
  #
  #   1. The SyncClipboard password must be treated as exposed and rotated once
  #      every client uses the HTTPS name and the `clipboard` entry's `legacy`
  #      list is emptied. Rotating before then re-exposes the new password by the
  #      same route. The value lives in the `docker/sdrhub/syncclipboard.env`
  #      sops secret and in each client's config.
  #   2. Deleting the legacy clipboard vhost is the actual fix, and is
  #      deliberately not done here: the mobile SyncClipboard clients are
  #      configured out-of-band and are not in this repository, so this would
  #      break them silently. Emptying `legacy` on the `clipboard` entry is the
  #      one-line change once they are migrated -- and the matching
  #      http://clipboard.sdrhub.local/ entry in
  #      modules/monitoring/master/blackbox.nix must go with it.
  #
  # HSTS is deliberately NOT the mitigation, despite being the obvious
  # suggestion. It is scoped to the host that sends it, so a header on
  # clipboard.int.fredsystems.org has no effect whatsoever on requests to
  # clipboard.sdrhub.lan -- a different name in a different, non-public zone.
  # It also cannot help here even in principle: the clients are native
  # SyncClipboard apps, not browsers, and do not implement HSTS. Meanwhile it
  # has a real cost on this host -- a failed renewal of the wildcard would leave
  # browsers unable to click through to adguard and grafana, which is exactly
  # when reaching the DNS control plane matters most. See the recovery note on
  # migratedVhosts above.
  legacyRedirectVirtualHosts = lib.mapAttrs' (
    name: def:
    lib.nameValuePair (lib.head def.legacy) (
      {
        serverAliases = lib.tail def.legacy;
        locations."/".return = "308 https://${name}.${internalDomain}$request_uri";
      }
      // lib.optionalAttrs (def.legacyDefault or false) { default = true; }
    )
    # Services with no legacy names get no plaintext server block. Filtered
    # rather than handled inside the mapper because `lib.head []` is an error,
    # and because "there is nothing to be backward-compatible with" is a
    # meaningfully different statement from "the redirect is empty".
  ) (lib.filterAttrs (_: def: def.legacy != [ ]) migratedVhosts);

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

  # TLS names under internalDomain that are served by a DIFFERENT host, so they
  # cannot come from migratedVhosts above -- that map is specifically the vhosts
  # this host's nginx terminates, and its answer is hardcoded to sdrhub.
  #
  # attic, ai and jellyfin live on fredhub and terminate TLS there rather than
  # being proxied through here. For attic that is the point: proxying would
  # leave the push token in cleartext on the sdrhub -> fredhub hop, which is the
  # whole thing it exists to prevent. ai and jellyfin had exactly that defect --
  # the client saw TLS while their logins crossed the LAN in the clear on the
  # second hop -- and the fix is to remove the hop rather than encrypt it. See
  # hosts/linux/fredhub/nginx.nix.
  #
  # nvr is the Frigate UI on nvrhub and is here for the same reason: Frigate has
  # its own login, so proxying it through this host would put those credentials
  # on the wire in the clear on the second hop. See
  # hosts/linux/nvrhub/nginx.nix.
  externalTlsHosts = {
    attic = "192.168.31.14";
    ai = "192.168.31.14";
    jellyfin = "192.168.31.14";
    nvr = "192.168.31.179";
  };

  externalTlsRewrites = lib.mapAttrsToList (name: ip: {
    enabled = true;
    domain = "${name}.${internalDomain}";
    answer = ip;
  }) externalTlsHosts;

  # The plaintext `.lan` aliases for services that USED to be served here and
  # have since moved to another host.
  #
  # They still resolve to sdrhub (they are in lanHosts), so without these there
  # would be nothing listening for them and an old bookmark would get the
  # catch-all rather than a redirect. Same 308 the migratedVhosts entries emit,
  # pointing at whichever host now serves the name.
  relocatedLegacyVhosts =
    lib.mapAttrs'
      (
        name: legacy:
        lib.nameValuePair (lib.head legacy) {
          serverAliases = lib.tail legacy;
          locations."/".return = "308 https://${name}.${internalDomain}$request_uri";
        }
      )
      {
        ai = [
          "ai.sdrhub.lan"
          "ai.sdrhub.local"
        ];
        jellyfin = [
          "jellyfin.sdrhub.lan"
          "jellyfin.sdrhub.local"
        ];
      };
in
{
  imports = [
    ./hardware-configuration.nix
    ./acme.nix
    ../../../modules/secrets/sops.nix
    ../../../modules/services/adsb-docker-units.nix
    ../../../modules/services/sqlite-backup.nix
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
        # DNS over TCP.
        #
        # Not optional: RFC 7766 makes TCP a required transport for every DNS
        # server, and it is how a resolver recovers when a UDP answer comes back
        # truncated (TC=1). Without it those names simply fail rather than
        # retrying, which is a silent, per-name, intermittent fault -- the worst
        # kind to notice.
        #
        # AdGuard has been listening on TCP 53 the whole time (`ss -tlnp` shows
        # AdGuardHome on `*:53`); only the firewall was dropping it, so this
        # opens an existing listener rather than exposing anything new. The
        # audience is unchanged too: UDP 53 was already open to the same LAN.
        #
        # Measured before adding, so the size of the problem is on record rather
        # than assumed. With unbound advertising `edns-buffer-size: 1232` (the
        # DNS Flag Day 2020 value), nothing in normal use truncates -- the root
        # DNSKEY, the largest realistic case, comes back at 1139 bytes. So this
        # is a correctness fix for the tail (long SPF/TXT chains, DNSSEC-heavy
        # zones, ANY queries), not a fix for anything currently failing, and it
        # is unrelated to the 2026-08-15/16 outages.
        #
        # Note there is deliberately no blackbox probe for this. The exporter
        # runs on this host, and traffic to sdrhub's own address arrives over
        # `lo`, which is in trustedInterfaces -- so a probe would pass whether or
        # not this rule existed, asserting something weaker than it appears to.
        #
        # Global rather than scoped to the LAN interface via
        # `networking.firewall.interfaces.<name>`, and that is a considered
        # choice rather than laziness. This host declares no interface names at
        # all -- `networking.useDHCP = true` in hardware-configuration.nix and
        # `networking.interfaces` evaluates to `{}` -- so scoping means
        # hardcoding a kernel-assigned name (`enp89s0`) that appears nowhere
        # else in the configuration. Get it wrong, or have it renamed by a NIC
        # or kernel change, and there is no rule at all: the default policy
        # drops, and the entire LAN loses DNS with a config that still builds
        # and deploys cleanly. That is the same class of silent, invisible-from-
        # reading-the-config fault as the AdGuard bind bug below.
        #
        # It would also narrow more than intended. `trustedInterfaces` on this
        # host is `[ "lo" ]` and nothing more -- verified, not assumed:
        #
        #   nix eval '.#nixosConfigurations.sdrhub.config.networking.firewall.trustedInterfaces'
        #
        # so `tailscale0` is NOT trusted and DNS reachable over the tailnet
        # depends on this global rule. Scoping to the LAN interface would
        # silently remove that while leaving the LAN exposure -- which is the
        # exposure -- exactly as it was.
        53
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

          # Both of these exist for the exporter in
          # modules/monitoring/master/unbound-exporter.nix, which asserts they
          # are on rather than silently producing a useless scrape.
          #
          # extended-statistics is what produces the rcode counters, including
          # num.answer.rcode.SERVFAIL. Without it unbound exposes NONE of them
          # -- verified by `unbound-control stats | grep -c rcode` returning 0 --
          # which meant the single number that would have quantified the
          # 2026-08-15 and 2026-08-16 outages was never collected. Upstream
          # notes it costs some time to track; on a home LAN's query volume that
          # is not measurable.
          #
          # statistics-cumulative makes the counters monotonic instead of being
          # cleared on read. Without it `unbound-control stats` RESETS every
          # counter, so the exporter and a human debugging by hand silently
          # destroy each other's numbers -- observed while investigating: a read
          # returned 91 queries and the next read, seconds later, returned 0.
          # Prometheus also wants counters that only go up.
          extended-statistics = true;
          statistics-cumulative = true;

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

      # The admin UI binds loopback and is reached only through the nginx vhost,
      # like grafana and karma. It is a control plane for the LAN's DNS -- it can
      # rewrite any name, disable filtering, or read the full query log -- and it
      # was previously on 0.0.0.0:3000 with that port opened in the firewall and
      # no TLS, so its login crossed the LAN in cleartext.
      #
      # These are `host`/`port` rather than `settings.http.address`, and that
      # distinction is the whole bug. This config used to say
      # `settings.http.address = "127.0.0.1:3003"`, which reads as if it bound
      # loopback and never did: the nixpkgs module builds its config as
      #
      #     cfg.settings // { http.address = "${cfg.host}:${toString cfg.port}"; }
      #
      # so the module's own defaults (0.0.0.0 and 3000) overwrite whatever
      # `settings.http` contains, every time. Verified by reading the generated
      # config out of the deployed closure, which contained `address:
      # 0.0.0.0:3000` despite the source asking for 127.0.0.1:3003. Setting it
      # under `settings` is not merely ineffective, it is actively misleading.
      #
      # Note `//` is a shallow merge, so it replaces the entire `http` attribute
      # set. Anything else that needs to live under `http` has to go through
      # module options too, or it will be silently dropped.
      #
      # Neither option touches DNS. `host` and `port` are used in exactly two
      # places in that module -- the web address above and the openFirewall line
      # -- and the DNS listener comes from `settings.dns` and the explicit
      # `allowedUDPPorts = [ 53 ]` in the firewall block near the top of this
      # file.
      host = "127.0.0.1";
      port = 3003;

      # Was true, which opened `port` to the LAN. That is the opening that made
      # the admin UI reachable at http://192.168.31.20:3000/. nginx reaches it
      # over loopback, so nothing needs it open.
      openFirewall = false;

      settings = {
        dns = {
          upstream_dns = [ "127.0.0.1:5335" ];
          enable_dnssec = true;
          rate_limit = 0;

          # Fallback upstreams, used when the primary is NOT RESPONDING -- a
          # timeout or a network error, not an rcode.
          #
          # Read that limitation before assuming what this protects against,
          # because it is narrower than it looks. During the 2026-08-16 outage
          # unbound was responding perfectly well; it was returning SERVFAIL
          # because its own upstreams had gone away. AdGuard counts a SERVFAIL
          # as a successful exchange, so these fallbacks would NOT have engaged
          # and this would have changed nothing. The fix for that failure is the
          # second provider in unbound's forward-zone above, not this block.
          #
          # What this does cover is unbound being unavailable rather than
          # unhappy: crashed, restarting mid-deploy, or not yet listening on
          # 5335. That is currently an unmitigated single point of failure,
          # because upstream_dns has exactly one entry and it points at unbound.
          #
          # DoT rather than plain DNS, so the fallback path is no less private
          # than the primary. Hostnames rather than bare IPs so the certificate
          # can be verified by name -- that costs a bootstrap lookup, which is
          # why bootstrap_dns below is no longer single-provider either.
          fallback_dns = [
            "tls://dns11.quad9.net"
            "tls://security.cloudflare-dns.com"
          ];

          # Used only to resolve the hostnames in fallback_dns. Plain DNS by
          # necessity -- it is the chicken-and-egg step before an encrypted
          # upstream can be dialled -- so these are the providers' unfiltered
          # addresses and nothing sensitive rides on them.
          #
          # Declared here rather than left to AdGuard's default for two reasons.
          # The default was Quad9-only, which would have made the fallback
          # unable to bootstrap during exactly the outage it exists for. And the
          # default includes IPv6 addresses (2620:fe::10 and friends) on a
          # network that has no IPv6 route at all -- see the note in
          # modules/monitoring/master/blackbox.nix -- so those can only ever
          # contribute a timeout before the v4 addresses are tried.
          bootstrap_dns = [
            "9.9.9.10"
            "149.112.112.10"
            "1.1.1.1"
            "1.0.0.1"
          ];

          edns_client_subnet = {
            enabled = true;
          };
        };

        filtering = {
          protection_enabled = true;
          filtering_enabled = true;
          parental_enabled = false;
          safe_search.enabled = false;

          rewrites = mkRewrites lanHosts ++ tlsRewrites ++ externalTlsRewrites;
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
        image = "amir20/dozzle:v10.7.4@sha256:068025ea622a1ce3e343a138dd9a962429b5187a133aca301bb4991fe7d2b708";

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
        image = "ghcr.io/sdr-enthusiasts/docker-adsb-ultrafeeder:telegraf-build-955@sha256:b05c0587d027b4d1784d7bfb857a693c6d29a5d6e02761afda30b5ed5d9a3327";

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
        image = "ghcr.io/sdr-enthusiasts/docker-opensky-network:latest-build-845@sha256:b50bc8c2e7fc9b6c7048592915c1203caaf267dcf5f8d4a180622d1e98920fc2";

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
        #image = "ghcr.io/rpatel3001/docker-acars2pos:latest-build-31@sha256:229f6ee8a65a25989aacf62e2f93b30dff86066a9684396e599a95ccb049b834";
        image = "ghcr.io/fredclausen/docker-acars2pos:latest-build-1@sha256:a68723c89cd79596e717285671f95c06badab5b25ab79058b574ec1ec192cca5";

        restart = "always";
        tty = true;

        # Drop the periodic per-airline statistics dump.
        #
        # Measured 2026-08-18: this container emitted 15,510 journal
        # lines/hour, of which 13,731 -- 88.5% -- were one pretty-printed
        # Python dict re-emitted roughly every 20 seconds, 80 lines per burst,
        # one line per airline code. Every line looks like
        #
        #   {'81': {'airframes': 0, 'python': 0, 'total': 1},
        #    'AA': {'airframes': 0, 'python': 0, 'total': 1},
        #
        # It was also double-counted: docker.service relays container stdout,
        # so the same 14k lines/hour appeared a second time under that unit,
        # making the pair the top two journal producers on this host after
        # Loki itself.
        #
        # The image has no verbosity control, so this is filtered here instead.
        # The pattern anchors on the `'XX': {'airframes'` shape rather than the
        # bare word, so it catches both the opening line and the
        # leading-whitespace continuations while leaving anything else that
        # merely mentions airframes alone. Verified against real burst output
        # with systemd-run before landing: all three dict line shapes dropped,
        # "matched message type" and "acars NN" preserved.
        #
        # Position data itself is untouched -- this drops only the aggregate
        # counters, which are visible in Prometheus anyway.
        logFilterPatterns = [ "~'[^']*': \\{'airframes'" ];

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
        // relocatedLegacyVhosts
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
          # rejectSSL rather than a certificate, unlike fredvps: this emits
          # `ssl_reject_handshake on;`, so nginx aborts the handshake with an
          # `unrecognized_name` alert before a certificate is chosen. There is
          # therefore no certificate to declare at all. The alternative --
          # generating a throwaway self-signed pair in the derivation -- is
          # worse than it looks: `openssl req -newkey` draws fresh randomness on
          # every build, so the same store path would hold a different NAR on
          # each builder, which breaks reproducibility and the binary cache.
          #
          # An explicit `listen` rather than letting the module derive it. Without
          # rejectSSL implying onlySSL, the module would also emit a port 80
          # `default_server` line here, and the plaintext landing page above
          # already claims that -- nginx refuses to start on the duplicate. The
          # addresses come from the module's own default list so this cannot
          # drift from what the other vhosts bind.
          "_" = {
            default = true;
            serverName = "_";
            rejectSSL = true;
            listen = map (addr: {
              inherit addr;
              port = 443;
              ssl = true;
            }) config.services.nginx.defaultListenAddresses;
          };
        };
    };

    # Consistent dumps of the two ACARS message databases.
    #
    # These are the only data under /opt/adsb that genuinely needs backing up,
    # and until now they were the part being backed up WORST: the NAS's nightly
    # rsync of /opt/adsb copied both live, WAL-mode, mid-write, which is the
    # exact defect the audit found and fixed in discord-backup.nix. Everything
    # else in that tree -- influxdb_data, tar1090_heatmap, vrs, pihole,
    # fam_webapp -- is cache or regenerable state, and accounts for 9.17 of the
    # 11.99 GiB the pull currently transfers. Measured 2026-08-18:
    #
    #   acarshub   messages.db  1.41 GiB   \ 2.82 GiB, i.e. 24% of the tree
    #   acarshubv4 messages.db  1.41 GiB   /
    #
    # Written into /opt/adsb/backups so the existing NAS job collects them with
    # no change at the NAS end. That placement is deliberate but has a
    # consequence worth knowing: the NAS pull passes --delete, so local retention
    # is mirrored rather than accumulated off-host. See BACKUP-DESIGN.md Part 3.
    #
    # Verified on this host before landing: `.backup` against the live database
    # takes ~5s per 1.4 GB, and the resulting dump passes integrity_check with
    # 3,448,426 rows and all five messages_fts* shadow tables present.
    sqliteBackup = {
      enable = true;

      databases = {
        acarshub = {
          source = "/opt/adsb/data/acarshub/messages.db";
          destination = "/opt/adsb/backups";
          name = "acarshub-messages";
        };

        acarshubv4 = {
          source = "/opt/adsb/data/acarshubv4/messages.db";
          destination = "/opt/adsb/backups";
          name = "acarshubv4-messages";
        };
      };
    };

    # Watch the dumps above, same as the Prometheus snapshots and the Discord
    # database. Without this they would be exactly what the rest of this fleet's
    # backups were before the freshness work: files nobody looks at, whose
    # absence is indistinguishable from health.
    #
    # `services.backupFreshness.enable` is already set by
    # modules/monitoring/master/prometheus.nix on this host; artifacts is an
    # attrset so these merge with the prometheus-tsdb entry declared there.
    backupFreshness.artifacts = {
      acarshub-db = {
        path = "/opt/adsb/backups";
        pattern = "acarshub-messages-*.sqlite";

        # 30 hours, matching the other nightly artifacts: the timer is 00:30 plus
        # up to 10 minutes of jitter, so a healthy newest-dump age peaks a little
        # over 24h just before each run.
        maxAgeSeconds = 108000;

        # keep = 3 in the sqliteBackup declaration above, so 3 is the steady
        # state. 5 catches the retention prune having stopped before three 1.4 GB
        # dumps become ten.
        maxCount = 5;

        description = "ACARSHub message database (acarshub)";
      };

      acarshubv4-db = {
        path = "/opt/adsb/backups";
        pattern = "acarshubv4-messages-*.sqlite";
        maxAgeSeconds = 108000;
        maxCount = 5;
        description = "ACARSHub message database (acarshubv4)";
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
    # Grafana builds absolute URLs -- login redirects, alert links, share URLs --
    # from its own root_url, which is set in
    # modules/monitoring/master/grafana.nix and has no way to know what name
    # nginx actually serves it under. If the two drift, Grafana keeps working
    # while handing browsers links to a name that does not resolve, which is the
    # sort of fault that gets blamed on the browser for a while.
    {
      assertion =
        config.services.grafana.settings.server.root_url == "https://grafana.${internalDomain}/";
      message = ''
        sdrhub: services.grafana.settings.server.root_url is
        "${config.services.grafana.settings.server.root_url}", but nginx serves
        Grafana at "https://grafana.${internalDomain}/".

        Set root_url (and `domain`) in modules/monitoring/master/grafana.nix to
        match, or rename the `grafana` entry in migratedVhosts.
      '';
    }

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
