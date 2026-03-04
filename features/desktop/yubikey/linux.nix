{
  pkgs,
  ...
}:
{
  services = {
    pcscd.enable = true;

    udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="1050", \
        TAG+="systemd", ENV{SYSTEMD_USER_WANTS}+="yubikey-git-update.service"
    '';
  };

  systemd.user.services.yubikey-git-update = {
    description = "Update Git signing key based on YubiKey presence";

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.writeShellScript "yubikey-git-update" ''
                set -euo pipefail

                MAP="$HOME/.config/git/yubikey-map"
                OUT="$HOME/.config/git/signing.conf"
                TMP="$(mktemp)"

                mkdir -p "$(dirname "$OUT")"

                SERIALS="$(${pkgs.yubikey-manager}/bin/ykman list --serials 2>/dev/null || true)"
                matches=()

                while read -r serial key; do
                  if echo "$SERIALS" | grep -qx "$serial"; then
                    matches+=("$key")
                  fi
                done < "$MAP"

                if (( ''${#matches[@]} == 1 )); then
        cat >"$TMP" <<EOF
        [user]
          signingkey = ''${matches[0]}
        EOF
                  mv "$TMP" "$OUT"
                else
                  rm -f "$OUT"
                fi
      ''}";
    };
  };

  security = {
    pam.services = {
      sudo.u2fAuth = true;
      swaylock.u2fAuth = true;
    };
  };
}
