# TLS for the Frigate web UI, as nvr.int.fredsystems.org.
#
# WHY TLS TERMINATES HERE AND NOT ON SDRHUB
#
# sdrhub already runs nginx with a wildcard certificate and a landing page, so
# proxying through it is the obvious cheap option. It is the same mistake that
# hosts/linux/fredhub/nginx.nix exists to document:
#
#     browser --https--> sdrhub --plain http--> nvrhub
#
# Frigate has its own login (frigate/api/auth.py), so the credential would
# cross the LAN in the clear on that second hop while the browser showed a
# padlock. Removing the hop is the fix, not encrypting the first half of it.
# sdrhub's `externalTlsHosts` map exists precisely for names like this one and
# now carries an `nvr` entry pointing here.
#
# WHY THIS RENAMES THE EXISTING VHOST RATHER THAN ADDING ONE
#
# The obvious-looking alternative -- leave Frigate on nvrhub.local and add a
# second TLS vhost proxying to it -- is actively dangerous, and the trap is
# already written up in ./frigate.nix. The nixpkgs module gives Frigate's vhost
# a `listen 127.0.0.1:5000`, and Frigate treats ANY request arriving on port
# 5000 as pre-authenticated:
#
#     # dont require auth if the request is on the internal port
#     if int(request.headers.get("x-server-port", default=0)) == 5000:
#         success_response.headers["remote-user"] = "anonymous"
#
# A new vhost proxying to 127.0.0.1:5000 would therefore publish the entire
# Frigate API -- events, recordings, snapshots -- to anyone who could reach the
# TLS name, with no login at all. That exact mistake was made and caught in
# review on PR #2191 when a socat relay was used for the metrics endpoint.
#
# The module builds its vhost as `virtualHosts."${cfg.hostname}"` and uses
# `cfg.hostname` for nothing else (verified: it is the only reference in
# services/video/frigate.nix). So pointing `hostname` at the TLS name reuses
# the module's entire auth_request pipeline as-is, and this file only has to
# add the certificate. Nothing about how Frigate is proxied is duplicated here,
# which is the point -- that logic is intricate and must not be forked.
{ config, ... }:
let
  internalDomain = "int.fredsystems.org";
  fqdn = "nvr.${internalDomain}";
in
{
  # Same token sdrhub and fredhub use, scoped to Zone:Read + DNS:Edit on
  # fredsystems.org. nvrhub is already an age recipient for secrets.yaml.
  sops.secrets.cloudflare_acme_token = {
    # Without this, rotating the shared token and redeploying leaves lego
    # holding the stale value with no error and no restart -- the same
    # silent-stale-credential failure documented for the camera credentials in
    # ./frigate.nix and for the attic token in
    # ../../../modules/services/attic/attic_server.nix.
    restartUnits = [ "acme-${fqdn}.service" ];
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "clausen.fred@me.com";

    certs.${fqdn} = {
      # DNS-01, not HTTP-01. This host is not reachable from the internet and
      # the name lives in a split-horizon zone, so there is no way to answer a
      # HTTP challenge. It also means port 80 is never needed for issuance --
      # see the firewall note below.
      dnsProvider = "cloudflare";

      # credentialFiles rather than environmentFile: rendered as a systemd
      # LoadCredential, and lego reads the `_FILE` variant, so the token never
      # lands in the unit environment where `systemctl show` would print it.
      credentialFiles.CF_DNS_API_TOKEN_FILE = config.sops.secrets.cloudflare_acme_token.path;

      # Do not resolve the propagation check through this network's own DNS.
      # sdrhub runs AdGuard with split-horizon rewrites in front of Unbound, and
      # this check polls a record created seconds earlier -- exactly the shape a
      # cached negative answer turns into a failed renewal months later.
      dnsResolver = "1.1.1.1:53";

      # Without this the certificate is group `acme` and nginx cannot read
      # key.pem. The nginx module wires reloadServices for a useACMEHost vhost
      # but deliberately leaves `group` alone.
      group = "nginx";
    };
  };

  # Renaming the module's vhost to the TLS name. See the header for why this is
  # a rename rather than an addition.
  services.frigate.hostname = fqdn;

  services.nginx.virtualHosts = {
    ${fqdn} = {
      forceSSL = true;
      useACMEHost = fqdn;
    };

    # Plaintext redirect for the old name.
    #
    # `nvrhub.local` was the vhost name until this change and is what any
    # existing bookmark uses. Mirrors sdrhub's legacyRedirectVirtualHosts
    # pattern: the serving config exists once, on the TLS vhost, and this is a
    # redirect rather than a second copy that could drift.
    #
    # Deliberately NOT a serverAlias on the vhost above. An alias would be
    # served over TLS under a certificate that covers only nvr.int...., so every
    # visit would raise a name-mismatch warning -- training exactly the
    # click-through habit that makes the certificate pointless.
    "nvrhub.local" = {
      serverAliases = [
        "nvrhub"
        "nvrhub.lan"
      ];
      locations."/".return = "308 https://${fqdn}$request_uri";
    };
  };

  networking.firewall.allowedTCPPorts = [
    # 80 serves only the redirect above and forceSSL's generated
    # http -> https redirect. It is NOT needed for certificate issuance, which
    # is DNS-01. Without it a client reaching for the old http://nvrhub.local
    # gets a connection timeout rather than being told where to go.
    80
    443
  ];
}
