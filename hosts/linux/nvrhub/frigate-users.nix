# Frigate logins that other services use, kept in step with Nix.
#
# Frigate keeps its users as rows in its database, created through its API or
# UI, not in its config file. This oneshot makes each user below exist with
# its role and its sops password after every Frigate start, and changes
# nothing when they already match. Users not listed here (the built-in admin,
# people's own logins) are left alone.
#
# It talks to the module's loopback-only 127.0.0.1:5000 listener, where nginx
# treats requests as Frigate's internal port and so as admin (see the metrics
# notes in ./frigate.nix). Nothing outside this host reaches that listener.
#
#   homeassistant  Home Assistant's Frigate integration on corehub (Plan 06,
#                  6.11). viewer: it reads cameras, events and clips through
#                  the API, and switches cameras through MQTT, not the API.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  users = {
    homeassistant = {
      role = "viewer";
      secret = "home-assistant/frigate_password";
    };
  };

  api = "http://127.0.0.1:5000/api";

  ensure = pkgs.writeShellApplication {
    name = "frigate-ensure-users";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
    ];
    text = ''
      api=${api}

      # Frigate takes a while to start; wait for its API.
      for _ in $(seq 120); do
        curl -sf "$api/users" >/dev/null && break
        sleep 2
      done
      current=$(curl -sf "$api/users")

      changes=0
      ensure() {
        local user=$1 role=$2 password
        password=$(cat "$CREDENTIALS_DIRECTORY/$user")

        if ! jq -e --arg u "$user" 'any(.username == $u)' <<<"$current" >/dev/null; then
          jq -n --arg u "$user" --arg p "$password" --arg r "$role" \
            '{username: $u, password: $p, role: $r}' |
            curl -sf -X POST -H 'Content-Type: application/json' --data @- "$api/users" >/dev/null
          echo "created $user ($role)"
          changes=$((changes + 1))
          return
        fi

        if ! jq -e --arg u "$user" --arg r "$role" 'any(.username == $u and .role == $r)' <<<"$current" >/dev/null; then
          jq -n --arg r "$role" '{role: $r}' |
            curl -sf -X PUT -H 'Content-Type: application/json' --data @- "$api/users/$user/role" >/dev/null
          echo "set $user's role to $role"
          changes=$((changes + 1))
        fi

        # Only rewrite the password when the sops one no longer logs in.
        if ! jq -n --arg u "$user" --arg p "$password" '{user: $u, password: $p}' |
          curl -sf -o /dev/null -X POST -H 'Content-Type: application/json' --data @- "$api/login"; then
          jq -n --arg p "$password" '{password: $p}' |
            curl -sf -X PUT -H 'Content-Type: application/json' --data @- "$api/users/$user/password" >/dev/null
          echo "set $user's password"
          changes=$((changes + 1))
        fi
      }

      ${lib.concatStrings (lib.mapAttrsToList (user: u: "ensure ${user} ${u.role}\n") users)}
      echo "done: $changes changes"
    '';
  };
in
{
  systemd.services.frigate-users = {
    description = "Keep Frigate's service logins in step with Nix";
    after = [ "frigate.service" ];
    requires = [ "frigate.service" ];
    partOf = [ "frigate.service" ];
    wantedBy = [ "frigate.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe ensure;
      DynamicUser = true;
      LoadCredential = lib.mapAttrsToList (
        user: u: "${user}:${config.sops.secrets.${u.secret}.path}"
      ) users;
    };
  };

  sops.secrets = lib.mapAttrs' (
    _: u: lib.nameValuePair u.secret { restartUnits = [ "frigate-users.service" ]; }
  ) users;
}
