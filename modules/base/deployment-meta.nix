{
  config,
  lib,
  pkgs,
  isDarwin ? false,
  ...
}:
let
  cfg = config.deployment;
in
{
  options.deployment = {
    role = lib.mkOption {
      type = lib.types.str;
      default = "standalone";
      description = "Deployment role for this node (standalone | monitoring-agent | monitoring-master).";
    };

    scrapeAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Hostname or IP address Prometheus uses to scrape this node.
        When null, defaults to "<attr>.local", where <attr> is this host's
        nixosConfigurations attribute name in flake.nix -- NOT
        config.networking.hostName, which is not guaranteed to match (suitable
        for LAN nodes).
        Set this to a Tailscale MagicDNS name for nodes not on the LAN.
      '';
    };

    internetFacing = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether this node has an interface reachable from the public
        internet.

        Every host in this fleet except fredvps sits behind NAT on the LAN,
        so the monitoring exporters bind 0.0.0.0 and open their ports
        unconditionally -- which is harmless there and reachable only from
        the LAN. On a VPS that same configuration publishes them to the
        world: node_exporter served 3021 lines of host metrics and cAdvisor
        served per-container stats, both unauthenticated, to anyone who
        asked.

        Setting this to true makes the exporters bind the Tailscale address
        instead, and stops them opening a firewall port. Prometheus already
        scrapes such nodes over Tailscale (see scrapeAddress), so nothing
        legitimate is lost.

        Requires tailscaleAddress to be set.
      '';
    };

    tailscaleAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        This node's Tailscale IPv4 address, as a literal.

        ## Why a literal and not the MagicDNS name

        Everything that RESOLVES a name at runtime should use the MagicDNS
        name instead of this option -- see scrapeAddress, and the feed
        targets in secrets.yaml, which all use `<host>.<tailnet>.ts.net` and
        therefore survive a re-IP with no config change at all.

        This option exists for the cases that cannot do that, all of which
        need a literal address at BIND time:

          * `docker run -p <addr>:<host>:<container>` rejects a hostname
            outright ("docker: invalid IP address: ..." -- verified).
          * Exporter `listenAddress` / `host` options are rendered into unit
            files at build time, long before tailscaled exists to resolve
            anything.

        ## Durability

        Tailscale addresses are stable for as long as the node stays
        registered. They change only if the node is removed from the tailnet
        and re-added, Tailscale is reset or reinstalled, the disk is wiped
        and the node key lost, or an admin reassigns it via the IP pool.

        So: stable in normal operation, but NOT guaranteed across a rebuild.

        ## If the address changes

        Update this one option for the affected host. Every bind on that host
        is derived from it, so there is a single place to edit. The
        `tailscale-address-drift` unit below checks the configured value
        against the running one on every activation and warns loudly if they
        disagree, so a stale value is reported rather than discovered when a
        container fails to start.

        Nothing else needs touching: MagicDNS consumers follow automatically.
      '';
    };
  };

  # The isDarwin guard on the drift unit is load-bearing.
  #
  # This module is imported by BOTH mk-system.nix and mk-darwin-system.nix,
  # and nix-darwin has no `systemd` option at all. `lib.mkIf false { systemd
  # = ...; }` does NOT avoid that: mkIf defers the value, but the option path
  # is still resolved during merging, so Darwin fails to evaluate with
  # "The option `systemd' does not exist". The definition must be absent from
  # the merge list entirely, which is what lib.optional does here.
  config = lib.mkMerge (
    [
      {
        assertions = [
          {
            assertion = cfg.internetFacing -> cfg.tailscaleAddress != null;
            message = "deployment.internetFacing requires deployment.tailscaleAddress to be set.";
          }
        ];

        # Unlike the assertion above, a missing scrapeAddress does not break
        # eval -- it just means flake.nix's agentScrapeMap/desktopScrapeMap
        # (see the "Monitoring topology" section of flake.nix) fall back to
        # "<attr>.local" for this node, where <attr> is the nixosConfigurations
        # attribute name (flake.nix:319/334) -- NOT config.networking.hostName.
        # The two are not guaranteed to match (a mismatch already caused a real
        # bug in this repo: an alert rule excluded "daytona" while the actual
        # identifier was "Daytona"). That fallback is the right default for a
        # LAN host with mDNS, and exactly wrong for one whose exporters were
        # just rebound off the LAN by internetFacing itself: Prometheus would
        # keep trying an address the host most likely does not answer on (a
        # bare VPS in particular has no mDNS responder at all), so scrapes
        # fail closed and silently rather than pointing at the Tailscale
        # address this option's own doc comment says to use.
        warnings = lib.optional (cfg.internetFacing && cfg.scrapeAddress == null) ''
          deployment.internetFacing is set on this host, but deployment.scrapeAddress is not.

          Prometheus's target for this node falls back to "<attr>.local", where <attr> is this
          host's nixosConfigurations attribute name in flake.nix (not necessarily
          config.networking.hostName), which is unlikely to resolve for an internet-facing node (no
          LAN mDNS responder), while the exporters themselves are now bound to
          deployment.tailscaleAddress instead of 0.0.0.0. Scraping this host will most likely fail.
          Set deployment.scrapeAddress to this node's Tailscale MagicDNS name (see fredvps's
          configuration.nix for the pattern).
        '';
      }
    ]
    ++
      lib.optional (!isDarwin)
        # Detect a stale deployment.tailscaleAddress.
        #
        # The literal is baked into container port bindings and exporter listen
        # addresses at build time. If the node's real address changes, those
        # binds point at an address the host no longer holds: containers fail to
        # start and exporters fail to listen. Both are loud, but they are loud at
        # the wrong moment -- mid-deploy, with no indication of the cause.
        #
        # This compares the configured value against `tailscale ip -4` after
        # activation and logs a warning naming both. Deliberately a warning and
        # not a failure: a re-IP is exactly when deploys need to keep working so
        # the new value can be rolled out, and refusing to activate would leave
        # the host stuck on its old generation.
        # Guarded on isDarwin, not just on tailscaleAddress. This module is
        # imported by BOTH mk-system.nix and mk-darwin-system.nix, and nix-darwin
        # has no `systemd` option at all -- so `lib.mkIf false { systemd... }`
        # still fails evaluation with "The option `systemd' does not exist".
        # mkIf defers the VALUE, not the option lookup, so the attribute path has
        # to be absent from the definition entirely on Darwin.
        (
          lib.mkIf (!isDarwin && cfg.tailscaleAddress != null) {
            systemd.services.tailscale-address-drift = {
              description = "Warn if deployment.tailscaleAddress no longer matches the running Tailscale address";
              after = [ "tailscaled.service" ];
              wants = [ "tailscaled.service" ];
              wantedBy = [ "multi-user.target" ];

              # No RemainAfterExit. A successful oneshot that stays "active"
              # is not restarted by switch-to-configuration when its definition
              # is unchanged, so the check would only ever run at boot -- which
              # is precisely when it is least useful, since a re-IP typically
              # happens while the machine is up. Verified: the unit ran once at
              # boot and did not re-run across a later deploy.
              #
              # Letting it go inactive on success, plus the restartTriggers
              # below, makes every activation re-run it.
              serviceConfig = {
                Type = "oneshot";
              };

              # Re-run on every activation.
              #
              # `unitConfig.X-Restart-Triggers` is deliberately NOT derived from
              # config.system.build.toplevel -- that is the derivation this unit
              # is part of, and referencing it here is an evaluation cycle
              # ("infinite recursion", observed). system.configurationRevision is
              # also unavailable: this repo forbids putting the flake's git rev
              # into a closure, because it would change every host's store path
              # on every commit (see flake/lib/mk-system.nix).
              #
              # Instead the unit is simply allowed to go inactive on success,
              # and StartLimitIntervalSec=0 keeps repeated starts from being
              # rate-limited. switch-to-configuration starts inactive units that
              # are wantedBy an active target on every activation, which gives
              # the desired behaviour without a synthetic trigger.
              unitConfig.StartLimitIntervalSec = 0;

              script = ''
                set -uo pipefail

                configured=${lib.escapeShellArg cfg.tailscaleAddress}

                # tailscaled may still be coming up; this check is advisory, so a
                # transient failure to read the address is not worth failing on.
                actual="$(${pkgs.tailscale}/bin/tailscale ip -4 2>/dev/null | head -n1 || true)"

                if [ -z "$actual" ]; then
                  echo "tailscale-address-drift: could not read the current Tailscale address; skipping check"
                  exit 0
                fi

                if [ "$actual" != "$configured" ]; then
                  echo "tailscale-address-drift: MISMATCH" >&2
                  echo "  deployment.tailscaleAddress = $configured" >&2
                  echo "  actual tailscale ip -4      = $actual" >&2
                  echo "  Container port bindings and exporter listen addresses are" >&2
                  echo "  built from the configured value and will fail to bind." >&2
                  echo "  Fix: set deployment.tailscaleAddress = \"$actual\" for this host." >&2
                else
                  echo "tailscale-address-drift: ok ($actual)"
                fi
              '';
            };
          }
        )
  );
}
