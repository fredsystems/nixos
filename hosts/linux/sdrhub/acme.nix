# A genuine, publicly-trusted wildcard certificate for this host's LAN vhosts.
#
# WHY A REAL CERTIFICATE RATHER THAN A PRIVATE CA
#
# The clipboard vhost carries HTTP Basic credentials on every request, and its
# payload is whatever happened to be on a clipboard -- passwords included.
# Both crossed the LAN in plaintext. Its neighbours (tar1090, dump978,
# piaware, ...) carry neither, so "it matches the convention on this host" is
# a much weaker defence for this one than it looks.
#
# A private CA (mkcert and friends) would fix the plaintext but replaces it
# with a distribution problem: the root has to be installed AND trusted on
# every client. NixOS and macOS are easy. iOS needs a manually installed
# configuration profile plus the separate "Enable Full Trust for Root
# Certificates" toggle, per device, repeated on every rotation -- and iOS is
# not optional here, because Shortcuts is the only iOS path to this service.
# Renewal would also become ours to script.
#
# A publicly-trusted certificate has none of that. Every device already trusts
# Let's Encrypt, so there is no trust store to distribute at all.
#
# WHY A DOMAIN THAT DOES NOT RESOLVE PUBLICLY
#
# `.lan` is not a real TLD, so no public CA can ever issue for it -- that is
# the hard blocker on securing the existing names in place. int.fredsystems.org
# is real, so it can be issued for.
#
# DNS-01 is what makes pointing it at a private address fine: validation
# publishes a TXT record in the zone, and Let's Encrypt never connects to the
# host. So nothing in the public zone points at 192.168.31.20 -- these names
# do not resolve publicly at all. The AdGuard rewrites in configuration.nix
# answer them with the LAN address, on the LAN only. That is the same
# split-horizon mechanism already used for every `.lan` / `.local` name here.
#
# WHY A SEPARATE DOMAIN
#
# fredsystems.org is registered at Cloudflare purely to hold this zone.
# Deliberately NOT fredclausen.com: that zone lives at Hover, which exposes no
# DNS API, is not in lego's supported provider list, and whose DNS editor has
# no NS record type -- so it cannot even delegate a subzone to a provider that
# does. Keeping this in its own zone also leaves the real one untouched.
{ config, ... }:
{
  # Scoped to Zone:Read + DNS:Edit on fredsystems.org and nothing else. lego
  # needs both: Zone:Read to resolve the domain name to a zone ID, DNS:Edit to
  # write the challenge record. Left root-owned -- it is handed to the renewal
  # unit through systemd credentials below rather than being opened by a
  # service running as its own user.
  sops.secrets.cloudflare_acme_token = { };

  security.acme = {
    acceptTerms = true;
    defaults.email = "clausen.fred@me.com";

    certs."int.fredsystems.org" = {
      # One wildcard for the whole host, so migrating the next vhost is a
      # vhost change with no certificate work and no second rate-limit budget.
      #
      # `extraDomainNames` adds the bare name because a wildcard does not
      # match its own parent. Note it does not match two label levels either:
      # something like `a.b.int.fredsystems.org` would need its own entry.
      domain = "*.int.fredsystems.org";
      extraDomainNames = [ "int.fredsystems.org" ];

      dnsProvider = "cloudflare";

      # credentialFiles rather than environmentFile: this is rendered as a
      # systemd LoadCredential=, and lego reads the `_FILE` variant of the
      # variable (documented for every provider), so the token is never
      # expanded into the unit's environment where `systemctl show` would
      # print it.
      credentialFiles.CF_DNS_API_TOKEN_FILE = config.sops.secrets.cloudflare_acme_token.path;

      # Do NOT let lego use this host's own resolver for the DNS-01
      # propagation check.
      #
      # sdrhub runs AdGuard Home -- with split-horizon rewrites and three
      # blocklists -- in front of Unbound, and serves the LAN. The propagation
      # check is a tight polling loop against a TXT record that was created
      # seconds ago, which is precisely the shape that a cached negative
      # answer turns into a failed renewal 60 days from now, long after anyone
      # would connect the two events.
      #
      # Querying Cloudflare's resolver directly sidesteps the local stack
      # entirely, and since the zone is hosted at Cloudflare it is also the
      # recursive closest to the authoritative data.
      dnsResolver = "1.1.1.1:53";

      # Required, and easy to miss: certificates default to group `acme`, and
      # nginx cannot read key.pem out of that. The nginx module wires up
      # `reloadServices` by itself for a `useACMEHost` vhost but deliberately
      # leaves `group` alone, so this half has to be declared here. Without
      # it, nginx fails to start on the first renewal rather than at eval.
      group = "nginx";
    };
  };
}
