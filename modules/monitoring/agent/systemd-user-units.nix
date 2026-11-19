# Failed systemd USER units, exported through node_exporter's textfile
# collector. See systemd-user-units.sh for why node_exporter cannot see them
# itself and which series this writes.
#
# Imported by node_exporter.nix rather than agent/default.nix: desktops
# import only node_exporter.nix (profiles/desktop.nix), and this has to run
# wherever node_exporter does.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  collector = pkgs.writeShellApplication {
    name = "systemd-user-units-metric";
    runtimeInputs = [
      # The host's own systemd, so systemctl speaks the running manager's
      # protocol version.
      config.systemd.package
      pkgs.jq
      pkgs.coreutils
    ];
    text = builtins.readFile ./systemd-user-units.sh;
  };
in
{
  systemd = {
    services.systemd-user-units-metric = {
      description = "Emit failed systemd user units for Prometheus";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe collector;
      };
    };

    timers.systemd-user-units-metric = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # One loginctl call plus one systemctl call per user: cheap enough to
        # run often, and a failure should not take longer than this to show.
        OnCalendar = "*:0/5";
        Persistent = true;
      };
    };
  };
}
