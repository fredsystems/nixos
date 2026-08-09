{ lib, ... }:
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

        A literal rather than the MagicDNS name because it is consumed by
        `listenAddress` options that are rendered into unit files at build
        time, long before tailscaled exists to resolve anything. It is stable
        for the lifetime of the node in the tailnet.
      '';
    };
  };
}
