# TLS termination for the Attic binary cache.
#
# WHY THIS EXISTS
#
# `attic push` sends its bearer token in an Authorization header, and until now
# it did so over plain HTTP to 192.168.31.14:8080. Anyone on the LAN could read
# it in flight. That is not a theoretical concern for this service: attic signs
# whatever it is given with the cache's NAR signing key, so a stolen push token
# lets an attacker place content that every machine in the fleet then trusts.
#
# WHY IT TERMINATES HERE AND NOT ON SDRHUB
#
# sdrhub already has nginx and a wildcard certificate, so proxying through it
# looks like the cheap option. It does not work:
#
#     maranello --https--> sdrhub --plain http--> fredhub:8080
#
# The token would still cross the LAN in the clear on the second hop, exactly
# as it does today, while looking fixed. TLS has to end where atticd is.
#
# WHY ITS OWN CERTIFICATE RATHER THAN SDRHUB'S WILDCARD
#
# Two reasons. A wildcard's private key should not be copied between hosts, and
# two machines renewing the same `*.int.fredsystems.org` certificate would both
# write `_acme-challenge.int.fredsystems.org`, racing each other. A distinct
# name uses `_acme-challenge.attic.int.fredsystems.org` and cannot collide.
#
# WHAT DELIBERATELY DOES NOT MOVE
#
# The Nix substituter in modules/base/system.nix stays on
# http://192.168.31.14:8080/fred. Reads are anonymous and every NAR is
# signature-checked against trusted-public-keys, so plaintext costs only the
# privacy of which paths are fetched -- a MITM cannot inject anything Nix will
# accept. In exchange that path depends on nothing but this host being up and
# IP routing: no DNS, no certificate, no nginx. That matters most precisely
# when things are broken, which is when you are rebuilding from the cache.
# See agent-docs/ATTIC_OPERATIONS.md.
#
# Port 8080 therefore stays open. This adds a second, encrypted way in for the
# clients that carry a credential; it does not replace the first.
{ config, ... }:
{
  # Same token as sdrhub uses, scoped to Zone:Read + DNS:Edit on
  # fredsystems.org. Root-owned; handed to the renewal unit through systemd
  # credentials rather than being read by a service running as its own user.
  sops.secrets.cloudflare_acme_token = { };

  networking.firewall.allowedTCPPorts = [
    # 80 exists only for the redirect that `forceSSL` generates. Nothing here
    # is served over it, and it is not used for certificate issuance either --
    # this host validates over DNS-01, so there is no HTTP-01 challenge to
    # answer. Without it a client that reached for http:// gets a connection
    # timeout instead of being told where to go.
    80
    443
  ];

  security.acme = {
    acceptTerms = true;
    defaults.email = "clausen.fred@me.com";

    # One certificate covering every int.fredsystems.org name this host serves.
    #
    # The cert is *named* for attic because that was the first vhost here; the
    # name is only an identifier for the state directory and the `useACMEHost`
    # reference. `extraDomainNames` is what makes it cover the rest. One order
    # and one renewal beats three of each, and unlike sdrhub's wildcard it
    # cannot race another host on a shared `_acme-challenge` record, because
    # each name gets its own.
    certs."attic.int.fredsystems.org" = {
      extraDomainNames = [
        "ai.int.fredsystems.org"
        "jellyfin.int.fredsystems.org"
      ];

      dnsProvider = "cloudflare";

      # credentialFiles, not environmentFile: rendered as a systemd
      # LoadCredential, and lego reads the `_FILE` variant of the variable, so
      # the token never lands in the unit's environment where `systemctl show`
      # would print it.
      credentialFiles.CF_DNS_API_TOKEN_FILE = config.sops.secrets.cloudflare_acme_token.path;

      # Do not resolve the propagation check through this network's own DNS.
      # sdrhub runs AdGuard with split-horizon rewrites in front of Unbound, and
      # the check is a tight poll against a record created seconds earlier --
      # the exact shape that a cached negative answer turns into a failed
      # renewal months later. The zone is hosted at Cloudflare, so this is also
      # the recursive closest to the authoritative data.
      dnsResolver = "1.1.1.1:53";

      # Without this the certificate is group `acme` and nginx cannot read
      # key.pem. The nginx module wires `reloadServices` for a `useACMEHost`
      # vhost but deliberately leaves `group` alone.
      group = "nginx";
    };
  };

  services.nginx = {
    enable = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    # No recommendedGzipSettings. Everything of size passing through here is a
    # NAR that attic has already compressed, and the default gzip_types would
    # not match it anyway -- it would be CPU spent to no effect.

    # Both application vhosts below push updates over websockets, so they need
    # the upgrade dance. Same map sdrhub uses.
    appendHttpConfig = ''
      map $http_upgrade $connection_upgrade {
        default upgrade;
        "" close;
      }
    '';

    # OpenWebUI. Previously reached as ai.int.fredsystems.org on SDRHUB, which
    # proxied here over plain HTTP -- so the login crossed the LAN in cleartext
    # on that second hop even though the client saw TLS. Serving it from the
    # machine it actually runs on removes the hop rather than encrypting it,
    # which is both simpler and strictly better.
    #
    # The matching AdGuard rewrite now answers with this host; the `.lan` alias
    # still redirects from sdrhub for anything with an old bookmark.
    virtualHosts = {
      "ai.int.fredsystems.org" = {
        forceSSL = true;
        useACMEHost = "attic.int.fredsystems.org";

        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString config.ai.local-llm.webuiPort}";
          extraConfig = ''
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;

            # Model responses stream token by token. With buffering on, nginx
            # holds the whole reply and the UI appears frozen until it finishes.
            proxy_buffering off;

            # A long generation legitimately outlasts the 60s default.
            proxy_read_timeout 600s;
          '';
        };
      };

      # Jellyfin. Same second-hop problem as ai above, same fix.
      "jellyfin.int.fredsystems.org" = {
        forceSSL = true;
        useACMEHost = "attic.int.fredsystems.org";

        locations."/" = {
          proxyPass = "http://127.0.0.1:8096";
          extraConfig = ''
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;

            # Jellyfin streams media and pushes session state over a websocket;
            # buffering either would add latency for no benefit.
            proxy_buffering off;

            # Uploads (subtitles, artwork) and long-lived stream connections.
            client_max_body_size 512m;
            proxy_read_timeout 600s;
          '';
        };
      };

      "attic.int.fredsystems.org" = {
        forceSSL = true;
        useACMEHost = "attic.int.fredsystems.org";

        locations."/" = {
          proxyPass = "http://127.0.0.1:8080";

          extraConfig = ''
            # NAR uploads are large and unbounded. nginx defaults to a 1 MB body
            # limit, which would reject essentially every push with a 413 -- and
            # the client reports that as a generic upload failure, so it is worth
            # being explicit rather than picking a number that happens to work
            # until the day a big closure comes along.
            client_max_body_size 0;

            # Stream to atticd rather than spooling the whole body to disk first.
            # With buffering on, a multi-gigabyte push is written to nginx's temp
            # directory in full before atticd sees a single byte, which doubles
            # the I/O and can fill the disk.
            proxy_request_buffering off;

            # A large push legitimately takes minutes. The defaults are 60s, which
            # would cut long uploads off partway with a 504.
            proxy_read_timeout 600s;
            proxy_send_timeout 600s;
          '';
        };
      };
    };
  };
}
