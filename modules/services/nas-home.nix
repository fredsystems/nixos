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
  nasMountType = import ./nas-mount-type.nix { inherit lib; };
in
{
  options.nas = {
    enable = mkEnableOption "User-level NAS integration";

    mounts = mkOption {
      type = types.listOf nasMountType;
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

    # ensure user's systemd runs HM services
    systemd.user.startServices = true;

    # ====================================
    # GNOME bookmarks
    # ====================================
    systemd.user.services = lib.foldl' (
      acc: m:
      let
        bookmarkName = if m.gvfsName != "" then m.gvfsName else m.share;

        #encodedShare = lib.replaceStrings [ " " ] [ "%20" ] m.share;

        bookmarkUri = "file:///${m.path}";

        bookmarkLine = "${bookmarkUri} ${bookmarkName}";

        wifiCondition = if m.wifi != null then ''[ "$SSID" = "${m.wifi}" ]'' else "true";

        scriptFile = pkgs.writeShellScript "nas-bookmark-${lib.replaceStrings [ "/" ] [ "-" ] m.path}" ''
          BOOKMARK="$HOME/.config/gtk-3.0/bookmarks"
          mkdir -p "$(dirname "$BOOKMARK")"

          SSID="$(${cfg.wifiDetectionCmd})"

          if ${wifiCondition}; then
            if ! grep -Fxq "${bookmarkLine}" "$BOOKMARK" 2>/dev/null; then
              echo "${bookmarkLine}" >> "$BOOKMARK"
            fi
          else
            sed -i "\|${bookmarkLine}|d" "$BOOKMARK" 2>/dev/null || true
          fi
        '';
      in
      acc
      // {
        "nas-bookmark-${lib.replaceStrings [ "/" ] [ "-" ] m.path}" = {
          Unit = {
            Description = "NAS bookmark for ${bookmarkName}";
            After = [ "graphical-session.target" ];
          };

          Install = {
            WantedBy = [ "default.target" ];
          };

          Service = {
            Type = "oneshot";
            ExecStart = [ scriptFile ];
          };
        };
      }
    ) { } cfg.mounts;

  };
}
