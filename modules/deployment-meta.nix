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
  };
}
