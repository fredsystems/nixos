{
  config,
  lib,
  pkgs,
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
in
{
  options.nas = {
    enable = mkEnableOption "System-level NAS mounting";

    mounts = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            path = mkOption { type = types.str; };
            host = mkOption { type = types.str; };
            share = mkOption { type = types.str; };
            type = mkOption {
              type = types.enum [
                "nfs"
                "smb"
              ];
            };
            wifi = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Only mount when connected to this SSID.";
            };
            gvfsName = mkOption {
              type = types.str;
              default = "";
              description = "Display name used by the Home Manager NAS module.";
            };
            extraOptions = mkOption {
              type = types.listOf types.str;
              default = [ ];
            };
          };
        }
      );
      default = [ ];
    };

    wifiDetectionCmd = mkOption {
      type = types.str;
      default = ''
        nmcli -t -f active,ssid dev wifi | ${pkgs.gawk}/bin/awk -F: '$1=="yes"{print $2}'
      '';
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

          defaultOptions =
            if m.type == "nfs" then
              [
                "x-systemd.automount"
                "noauto"
                "nfsvers=3"
              ]
            else
              [
                "x-systemd.automount"
                "noauto"
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
