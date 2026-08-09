{
  config,
  lib,
  pkgs,
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
        When null, defaults to <hostname>.local (suitable for LAN nodes).
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

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.internetFacing -> cfg.tailscaleAddress != null;
          message = "deployment.internetFacing requires deployment.tailscaleAddress to be set.";
        }
      ];
    }

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
    (lib.mkIf (cfg.tailscaleAddress != null) {
      systemd.services.tailscale-address-drift = {
        description = "Warn if deployment.tailscaleAddress no longer matches the running Tailscale address";
        after = [ "tailscaled.service" ];
        wants = [ "tailscaled.service" ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

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
    })
  ];
}
