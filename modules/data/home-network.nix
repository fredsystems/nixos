{ lib, ... }:
{
  # Facts about the home network that more than one host needs to agree on.
  #
  # WHY THIS EXISTS AT ALL
  #
  # The home public address started life as a single literal in fredvps's
  # fail2ban ignoreIP list, where a hardcoded constant was the right shape --
  # one consumer, one file. It stopped being the right shape when sdrhub gained
  # a drift monitor for the same address, because the two would then have to be
  # kept in step by hand, and the failure mode of them disagreeing is the worst
  # possible one: the monitor reports "no drift" against its own stale copy
  # while fredvps bans the address the monitor is not watching.
  #
  # WHY NOT A FLAKE INPUT
  #
  # Flake inputs are pinned external sources resolved at lock time. Putting a
  # local, mutable fact in one would mean a flake.lock bump to record a new
  # address, and -- worse -- every input in this repo must be classified in four
  # separate places to satisfy the input-category sync invariant (flake.nix
  # comments, ci-linux.yaml, ci-darwin.yaml, and the impacted-hosts script).
  # A home IP address does not have a CI rebuild category. `shared.*` data
  # modules are the established pattern here; see nas-mounts.nix and
  # sync-hosts.nix alongside this file.
  #
  # COST OF LIVING HERE
  #
  # This is imported by mk-system.nix, so it is in every host's module set and
  # `modules/` matches CI's broad rebuild pattern. Changing the address triggers
  # a full-fleet rebuild. That is the right trade for a value that moves every
  # few months and whose staleness is an outage: cheap to change, expensive to
  # get wrong.
  options.shared.homePublicIPv4 = lib.mkOption {
    # strMatching rather than plain str, so a typo is an eval error rather than
    # a silently non-matching ignoreIP entry -- which would look exactly like
    # "correctly configured" right up until a ban.
    #
    # Octets are range-checked rather than just "one to three digits". The
    # looser pattern accepted 999.26.160.99, which defeats the entire point:
    # a fat-fingered octet is the most likely typo here and it would have
    # sailed through to ignoreIP as an address that can never match.
    type =
      let
        octet = "(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])";
      in
      lib.types.strMatching "^${octet}(\\.${octet}){3}$";
    default = "73.26.160.99";
    description = ''
      Current public IPv4 address of the home network, as observed by an
      off-site host.

      This is a Comcast residential address and therefore rotates. Two things
      depend on it being accurate:

        * fredvps's fail2ban ignoreIP list. The decoy jails run maxretry = 1,
          so a single SYN to any watched port from an address not on that list
          is an immediate host-wide ban that escalates on repeat. A stale entry
          here is a live outage risk, not a latent one.
        * sdrhub's home-ip-drift check, which compares this value against what
          fredvps actually observes and alerts on mismatch.

      When it rotates: update this value, deploy fredvps and sdrhub, and the
      HomePublicIPDrifted alert clears on the next check.

      IPv4 only, deliberately. Neither the home network nor fredclausen.com
      currently has usable IPv6 (no AAAA record, no global v6 at home), so
      there is no v6 path to ignore or monitor. If that changes, both the
      ignoreIP list and this module need a v6 sibling -- the decoy rules are
      installed with ip46tables and already log v6 knocks.
    '';
  };
}
