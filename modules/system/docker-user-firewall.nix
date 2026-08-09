# Default-deny for published Docker container ports.
#
# WHY THIS EXISTS
#
# `networking.firewall.allowedTCPPorts` does not constrain containers. Docker
# installs its own DNAT and filter rules, and the FORWARD chain reaches
# DOCKER-USER and DOCKER-FORWARD before nixos-fw ever sees the packet. So a
# container published with `-p 8081:80` is reachable from the internet even
# though the NixOS firewall never listed 8081.
#
# On fredvps that gap was live: tar1090, acarshub, the acarshub backend API,
# imageapi, fredsite, the Dozzle agent (which mounts docker.sock) and the
# whole ADS-B feed range were all publicly reachable while the declared
# firewall listed only 80, 443, 2269 and 8078. A confirmed Tor exit node and a
# Surfshark VPN endpoint were both found pulling the Beast feed on :30005, and
# neither appeared in nginx's logs because neither passed through nginx.
#
# The primary fix is to publish on an explicit bind address
# (`127.0.0.1:8081:80`), which is done per-container. This module is the
# backstop for the case that fix cannot cover: someone adds a container later,
# writes the port mapping the obvious way, and silently republishes it to the
# world. Binding is easy to forget precisely because it is invisible when it
# goes wrong -- nothing breaks, the port is just open.
#
# WHAT IT DOES
#
# Appends a default-drop to DOCKER-USER for packets arriving on the external
# interface, after allowing an explicit list of ports. Traffic from the
# loopback, the tailnet, and Docker's own bridges is untouched, as is anything
# belonging to an established connection.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dockerUserFirewall;
in
{
  options.dockerUserFirewall = {
    enable = lib.mkEnableOption ''
      a default-deny rule in the DOCKER-USER iptables chain, so that container
      ports published to 0.0.0.0 are not automatically reachable from the
      public internet
    '';

    externalInterface = lib.mkOption {
      type = lib.types.str;
      description = ''
        The public-facing interface. Only traffic ingressing here is filtered,
        so LAN and tailnet paths keep working regardless of this module.
      '';
      example = "enp1s0";
    };

    allowedTCPPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      description = ''
        Container ports that should stay reachable from the public internet.
        Ports served by a reverse proxy do NOT belong here: nginx connects
        over the loopback, which this module never filters.
      '';
    };

    allowedUDPPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      description = "As allowedTCPPorts, for UDP.";
    };
  };

  config = lib.mkIf cfg.enable {
    # A oneshot rather than a firewall extraCommands hook: Docker recreates
    # its chains on daemon restart, so the rules have to be (re)applied after
    # docker.service is up, not only at firewall start. Ordering after
    # docker.service and re-running on every activation keeps the two in sync.
    systemd.services.docker-user-firewall = {
      description = "Default-deny rules for published Docker ports (DOCKER-USER)";
      after = [
        "docker.service"
        "network-online.target"
      ];
      requires = [ "docker.service" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script =
        let
          ipt = "${pkgs.iptables}/bin/iptables";
          mkAllow =
            proto: port:
            "${ipt} -A DOCKER-USER -i ${cfg.externalInterface} -p ${proto} --dport ${toString port} -j RETURN";
          tcpAllows = map (mkAllow "tcp") cfg.allowedTCPPorts;
          udpAllows = map (mkAllow "udp") cfg.allowedUDPPorts;
        in
        ''
          set -euo pipefail

          # Idempotent: wipe our own rules before re-adding. -F only empties
          # the chain, it does not remove the FORWARD jump Docker installs.
          ${ipt} -F DOCKER-USER

          # Return traffic for connections we or a container initiated. This
          # must come first, otherwise outbound container connections break.
          ${ipt} -A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN

          # Explicitly published ports.
          ${lib.concatStringsSep "\n" tcpAllows}
          ${lib.concatStringsSep "\n" udpAllows}

          # Everything else arriving on the public interface is dropped.
          # DROP rather than REJECT: a scanner learns nothing from silence,
          # and these ports should look closed rather than filtered.
          ${ipt} -A DOCKER-USER -i ${cfg.externalInterface} -j DROP

          # Traffic from any other interface -- loopback, tailscale0, the
          # docker bridges -- falls through to Docker's own chains unchanged.
          ${ipt} -A DOCKER-USER -j RETURN
        '';
    };
  };
}
