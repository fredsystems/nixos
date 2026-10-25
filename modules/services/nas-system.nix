{
  config,
  lib,
  pkgs,
  utils,
  ...
}:

let
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    ;
  cfg = config.nas;
  nasMountType = import ./nas-mount-type.nix { inherit lib; };
in
{
  options.nas = {
    enable = mkEnableOption "System-level NAS mounting";

    mounts = mkOption {
      type = types.listOf nasMountType;
      default = [ ];
      description = "NAS shares to declare as on-demand (noauto) systemd mounts, optionally auto-started on a specific WiFi SSID.";
    };

    manageUsers = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Users allowed to start/stop the NAS mount units without authentication (used by the launcher entries from nas-home.nix).";
    };

    wifiDetectionCmd = mkOption {
      type = types.str;
      default = ''
        nmcli -t -f active,ssid dev wifi | ${pkgs.gawk}/bin/awk -F: '$1=="yes"{print $2}'
      '';
      description = "Shell command that prints the currently-associated WiFi SSID, used to gate WiFi-scoped mounts.";
    };
  };

  config = mkIf cfg.enable {

    # ====================================
    # system fileSystems mounts
    # ====================================
    fileSystems = lib.listToAttrs (
      map (
        m:
        let
          escapedShare = lib.replaceStrings [ " " ] [ "\\040" ] m.share;

          device = if m.type == "nfs" then "${m.host}:${escapedShare}" else "//${m.host}/${m.share}";

          # Deliberately no x-systemd.automount: anything that walks the mount
          # table would trigger it -- notably every buildFHSEnv app (Discord,
          # syncclipboard, Steam), whose bwrap setup recursively binds /mnt --
          # and with the NAS down or off-LAN each one then blocks until the
          # mount times out. Mounts are started explicitly instead (launcher
          # entries in nas-home.nix), and fail fast when the NAS is unreachable.
          mountTimeout = "x-systemd.mount-timeout=5s";

          defaultOptions =
            if m.type == "nfs" then
              [
                "noauto"
                mountTimeout
                "nfsvers=3"
              ]
            else
              [
                "noauto"
                mountTimeout
                "uid=1000"
                "gid=100"
                "noperm"
              ];
        in
        {
          name = m.path;
          value = {
            inherit device;
            fsType = m.type;
            options = defaultOptions ++ m.extraOptions;
          };
        }
      ) cfg.mounts
    );

    # ====================================
    # Let manageUsers start/stop exactly these mount units
    # ====================================
    security.polkit.extraConfig = mkIf (cfg.manageUsers != [ ]) ''
      polkit.addRule(function(action, subject) {
        var units = ${builtins.toJSON (map (m: "${utils.escapeSystemdPath m.path}.mount") cfg.mounts)};
        var users = ${builtins.toJSON cfg.manageUsers};
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            units.indexOf(action.lookup("unit")) >= 0 &&
            ["start", "stop", "restart"].indexOf(action.lookup("verb")) >= 0 &&
            users.indexOf(subject.user) >= 0) {
          return polkit.Result.YES;
        }
      });
    '';

    # ====================================
    # WiFi-gated systemd mount triggers
    # ====================================
    systemd.services = lib.foldl' (
      acc: m:
      if m.wifi != null then
        acc
        // {
          "nas-mount-${lib.replaceStrings [ "/" ] [ "-" ] m.path}" = {
            wantedBy = [
              "multi-user.target"
              "network-online.target"
            ];
            after = [ "network-online.target" ];

            serviceConfig.Type = "simple";

            script = ''
              SSID="$(${cfg.wifiDetectionCmd})"
              if [ "$SSID" = "${m.wifi}" ]; then
                systemctl start "$(systemd-escape -p ${m.path}).mount"
              else
                systemctl stop "$(systemd-escape -p ${m.path}).mount" 2>/dev/null || true
              fi
            '';
          };
        }
      else
        acc
    ) { } cfg.mounts;

  };
}
