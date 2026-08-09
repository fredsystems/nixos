{ config, lib, ... }:
let
  cfg = config.deployment;

  # On an internet-facing node these exporters must not be world-reachable:
  # cAdvisor serves per-container stats and node_exporter serves 3000+ lines
  # of host metrics, both unauthenticated. Prometheus scrapes such nodes over
  # Tailscale anyway, so binding the tailnet address loses nothing.
  bindAddress = if cfg.internetFacing then cfg.tailscaleAddress else "0.0.0.0";
in
{
  services = {
    #########################################################
    # cAdvisor
    #########################################################
    cadvisor = {
      enable = true;
      listenAddress = bindAddress;
      port = 4567;
    };
  };

  # Only punch a hole for LAN nodes. An internet-facing node reaches this
  # over Tailscale, whose traffic does not traverse nixos-fw's port rules.
  networking.firewall.allowedTCPPorts = lib.optionals (!cfg.internetFacing) [
    4567 # cAdvisor
  ];

  assertions = [
    {
      assertion = cfg.internetFacing -> cfg.tailscaleAddress != null;
      message = "deployment.internetFacing requires deployment.tailscaleAddress to be set.";
    }
  ];
}
