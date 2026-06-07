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
          set -u
          BOOKMARK="$HOME/.config/gtk-3.0/bookmarks"
          mkdir -p "$(dirname "$BOOKMARK")"
          touch "$BOOKMARK"

          SSID="$(${cfg.wifiDetectionCmd})"

          # Idempotent reconcile: always strip every existing copy of this
          # bookmark line first, then add back exactly one when the wifi
          # condition holds. The previous "append unless grep finds it"
          # approach could not self-heal duplicates that had already
          # accumulated (a missing guard in an earlier revision left
          # ~/.config/gtk-3.0/bookmarks with hundreds of repeated NAS
          # entries, which crashed gThumb's bookmark loader in memmove).
          #
          # One oneshot runs per mount and they all rewrite this single file,
          # so a lock serialises them (read-modify-write would otherwise race,
          # with the last `mv` clobbering a sibling's just-added line). The
          # rewrite via a temp file keeps each update atomic.
          exec ${pkgs.util-linux}/bin/flock "$BOOKMARK.lock" ${pkgs.bash}/bin/bash -c '
            BOOKMARK="$1"; line="$2"; want="$3"
            tmp="$(mktemp "$BOOKMARK.XXXXXX")"
            grep -Fxv "$line" "$BOOKMARK" > "$tmp" 2>/dev/null || true
            if [ "$want" = "1" ]; then
              echo "$line" >> "$tmp"
            fi
            mv "$tmp" "$BOOKMARK"
          ' bash "$BOOKMARK" "${bookmarkLine}" "$(if ${wifiCondition}; then echo 1; else echo 0; fi)"
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
