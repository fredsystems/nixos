# Grafana secret_key rotation

Runbook for rotating Grafana's `security.secret_key` on sdrhub, the only
host running Grafana in this fleet.

## Read this first

`secret_key` is Grafana's envelope-encryption root key. It signs auth
cookies and wraps the per-datasource secrets Grafana stores in its own
`secrets` database table. The full safety analysis for rotating it --
what is and is not protected by this key today -- lives in the comment
block above `sops.secrets."monitoring/grafana_secret_key"` in
`modules/monitoring/master/grafana.nix`. Read that before rotating; this
runbook does not repeat it.

Two consequences follow directly from that analysis, and both are
expected, not failures:

- **Every existing browser session is invalidated.** Cookies are signed
  with the old key; Grafana rejects them once the new key is loaded, and
  every logged-in user is sent back to the login page.
- **The 42 rows in `data_keys` become permanently undecryptable.** They
  protect nothing under the current datasource configuration (see the
  nix-file comment for the verification), so this is expected. Grafana
  logs decryption errors for them once after the restart and then moves
  on -- do not treat that log line as a failure.

The secret already carries `restartUnits = [ "grafana.service" ]`, so a
normal deploy restarts Grafana automatically once the sops value
changes. There is no separate restart step in this runbook.

## Procedure: rotate the secret_key

Use when the key may have leaked, or on a routine schedule. There is no
partial/rolling state here -- a deploy either has restarted Grafana with
the new key, or it has not.

1. Generate a new random value on any machine with `nix`:

   ```sh
   nix run nixpkgs#openssl -- rand -base64 32
   ```

2. Put it in sops, replacing the existing value, on a machine that has
   decrypt access (e.g. maranello):

   ```sh
   cd ~/GitHub/nixos
   sops modules/secrets/secrets.yaml
   # monitoring:
   #   grafana_secret_key: <paste>
   ```

3. Deploy sdrhub. This is the moment every existing session is
   invalidated and the `data_keys` rows above go stale:

   ```sh
   colmena apply --on sdrhub
   ```

4. Confirm Grafana actually restarted, the same way Procedure B in
   `ATTIC_OPERATIONS.md` confirms atticd restarted -- `restartUnits`
   handles this automatically, but a silent no-restart is exactly the
   failure mode that runbook exists to catch:

   ```sh
   ssh sdrhub 'systemctl show grafana -p ActiveEnterTimestamp'
   ```

   The timestamp must be from this deploy. If it predates the deploy,
   the unit did not restart and Grafana is still signing cookies with
   the old key.

5. Commit the sops change:

   ```sh
   git add modules/secrets/secrets.yaml && git commit
   ```

## Verifying a change

Do this from a browser, not `curl` with credentials on the command line --
both the session cookie and the admin password are secrets, and a shell
command line is world-readable to anyone on the box via `/proc` or shell
history for as long as it persists.

1. **Grafana is up and serving with the new process.** Load
   `https://grafana.int.fredsystems.org/login` -- expect the login page,
   not a connection error.

2. **An old session is rejected -- the user-visible proof the key
   actually rotated.** In a browser tab that was logged in before the
   deploy, reload any dashboard. Expect a redirect to the login page,
   not the dashboard.

3. **A fresh login still works.** Log in with the current admin
   credentials in that same browser. Expect success.

If you must script this (e.g. from an automation host with no browser),
put the cookie and password in files with `chmod 600`, pass them via
`curl`'s `-H @file` / `--data @file` forms, and delete the files
immediately after:

```sh
umask 077
printf 'Cookie: grafana_session=%s\n' "$OLD_SESSION_COOKIE" >cookie.hdr
printf '{"user":"admin","password":"%s"}\n' "$GRAFANA_PW" >login.json

curl -s -o /dev/null -w '%{http_code}\n' \
  -H @cookie.hdr https://grafana.int.fredsystems.org/api/user   # expect 401

curl -s -o /dev/null -w '%{http_code}\n' \
  -X POST -H 'Content-Type: application/json' --data @login.json \
  https://grafana.int.fredsystems.org/login                     # expect 200

rm -f cookie.hdr login.json
```

Then check the journal once for the expected, harmless `data_keys`
decryption errors and confirm nothing else is logged as failing:

```sh
ssh sdrhub 'journalctl -u grafana --since "10 minutes ago" | grep -i error'
```

Expect only decryption failures naming the stale `data_keys` rows.
Anything else (datasource provisioning errors, a crash loop) means the
rotation surfaced a problem the nix-file's safety analysis did not
anticipate -- stop and investigate before considering the rotation done.

## Invariants

- **`secret_key` lives only in sops**, never as a literal in
  `grafana.nix`. The pre-sops history of this file is the reason this
  invariant exists at all -- see the module comment.
- **A deploy is the only rotation mechanism.** There is no live-reload
  path; `restartUnits` is what makes the new value take effect.
- **Every rotation logs out every user.** This is not survivable to
  avoid -- do not schedule it during a live investigation that depends
  on someone's Grafana session staying open.
