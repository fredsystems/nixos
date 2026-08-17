# Attic operations

Runbook for the Attic binary cache on fredhub: renewing tokens, rotating the
signing key, and rebuilding the whole thing when the host is gone.

Three self-contained procedures. Pick the one that matches the situation; each
lists what breaks and for how long. Procedure A is the one you will actually
use.

## Read this first

Five facts. Everything below follows from them, and every one was verified
against the running server rather than taken from documentation.

**Reads are anonymous.** The `fred` cache is public and Nix pulls from it with
no credential. Verified three ways: unauthenticated `curl` on
`/fred/nix-cache-info` returns 200 with real content; there is no `netrc`
anywhere in the fleet, so Nix could not authenticate even if it wanted to; and
in `server/src/access/http.rs` a request with no token gets
`CachePermission::default()` plus `add_public_permissions()` for a public cache
— a code path that never consults a token at all.

The consequence is the one that matters: **rotating the signing key cannot
break a single build on a single machine.** Only pushes are affected.

**There is exactly one signing key, and no revocation.** `JWTSigningConfig` in
`server/src/config.rs` is an enum with one active variant, so two keys cannot be
valid at once. `revoke`, `revocation` and `jti` appear zero times in the token
crate, and `Token::from_jwt` is a stateless signature-and-expiry check. The only
way to invalidate a token is to replace the server key, which invalidates every
token simultaneously. There is no phased cutover.

**Minting is free.** `server/src/adm/command/make_token.rs` has no database
references; it is a pure function of the signing key and the claims. Minting
needs no restart, changes no server state, and invalidates nothing. Mint as
often as you like — a too-narrow token is a cheap mistake to correct.

**Push requires push *and* pull.** The client fetches cache config before
uploading, and that endpoint calls `require_pull()`. A push-only token fails.

**The NAR signing key is not the JWT key.** The JWT key authenticates clients.
The NAR signing key signs cache content and lives in atticd's database; its
public half is `trusted-public-keys` in `modules/base/system.nix`. Rotating the
JWT key leaves cached content valid. **Losing the database does not** — see
Procedure C.

## Where credentials live

| Credential          | Stored in                                  | Used by                              |
| ------------------- | ------------------------------------------ | ------------------------------------ |
| Server signing key  | sops `atticd_env`                          | atticd on fredhub                    |
| `desktop` token     | sops `attic/desktop_token`                 | maranello, daytona (`attic push`)    |
| `ci` token          | GitHub repo secret `ATTIC_TOKEN`           | the CI workflows                     |
| NAR signing pubkey  | `modules/base/system.nix`                  | every machine, to verify content     |

The CI workflows that push are `ci-linux.yaml`, `ci-darwin.yaml` and
`cache-flake-inputs.yaml`; each calls `attic login` with the secret.

Servers and the Macs hold no token. They only ever pull, anonymously. If a
machine needs push access that is a deliberate exception, not the default.

`atticd-atticadm` is a wrapper that runs `atticadm` under `systemd-run` with
`EnvironmentFile=/run/secrets/atticd_env`, so it picks up the live signing key
automatically. Run it as root on fredhub and it just works.

## Procedure A: renew tokens

Use when a token is near expiry. Tokens are minted for one year.

Nothing else is affected: no key rotation, no atticd restart, no impact on any
other token. The old tokens keep working until they expire on their own, so
there is no window at all.

On fredhub:

```sh
sudo atticd-atticadm make-token --validity "1y" --sub "desktop" \
  --push "fred" --pull "fred"

sudo atticd-atticadm make-token --validity "1y" --sub "ci" \
  --push "fred" --pull "fred"
```

Put the `desktop` token in sops, on maranello:

```sh
cd ~/GitHub/nixos
sops modules/secrets/secrets.yaml
# attic:
#   desktop_token: <paste>
```

Put the `ci` token in GitHub: **Settings, Secrets and variables, Actions,
`ATTIC_TOKEN`**.

Deploy **both** desktops and commit the sops change:

```sh
# on maranello
sudo nixos-rebuild switch --flake .#maranello

# on Daytona -- note the capital D, that is the attribute name
sudo nixos-rebuild switch --flake .#Daytona

git add modules/secrets/secrets.yaml && git commit
```

Daytona is not optional and is not covered by `colmena apply`: both desktops are
excluded from the colmena topology (see `flake/deployment/colmena.nix`), and both
set `programs.atticClient.tokenFile` in `home-profiles/desktop.nix`, which
`modules/services/attic/attic_client.nix` renders into `config.toml` during
home-manager activation. A desktop that is not activated keeps the token it last
activated with, and loses push access the moment that token expires or the
signing key is rotated. Commit only after both have activated, so the committed
sops value and the fleet agree.

Then run the checks in "Verifying a change" below.

## Procedure B: rotate the signing key

Use when a token has leaked. This is the only way to invalidate one.

Pushes fail from the atticd restart until the new tokens are distributed —
a few minutes. Reads are unaffected throughout, so no machine stops building.
Do it when CI is idle.

Generate a new key on fredhub:

```sh
nix run nixpkgs#openssl -- genrsa -traditional 4096 | base64 -w0
```

Put it in sops on maranello, replacing the existing value:

```sh
cd ~/GitHub/nixos
sops modules/secrets/secrets.yaml
# atticd_env:
#   ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64="<paste>"
```

Before deploying, check the paste survived. A corrupted key does not fail here
— it fails when atticd restarts, by which point every token is already dead:

```sh
sops -d --extract '["atticd_env"]' modules/secrets/secrets.yaml \
  | sed -n 's/^ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64="\(.*\)"$/\1/p' \
  | base64 -d | openssl rsa -check -noout; echo "exit=$?"
```

Want `RSA key ok` and `exit=0`. A 4096-bit key base64s to roughly 4324 bytes
and, because `base64 -w0` emits no trailing newline, zsh will show an inverse
`%` at the end of the generating command's output. That marker is not part of
the key — do not copy it.

Deploy fredhub. Every existing token dies at this moment:

```sh
colmena apply --on fredhub
```

Confirm atticd actually restarted, because this is the step that silently did
not work once:

```sh
ssh fredhub 'systemctl show atticd -p ActiveEnterTimestamp'
```

The timestamp must be from this deploy. If it is older, atticd is still holding
the previous key in memory and every token you mint next will be rejected — see
the `restartUnits` comment in `modules/services/attic/attic_server.nix`. The
failure looks like a permissions problem rather than a key problem, because a
signature the server cannot verify makes the request anonymous instead of
raising an authentication error:

```text
attic push -> 403 AccessError, identical with and without a token
```

`restartUnits` on the secret now handles this automatically, so the check is
belt and braces rather than a routine manual step.

Now run **Procedure A** to mint and distribute the replacements. That is the
whole of the rest of this procedure.

If it goes wrong, restore the previous `atticd_env` from sops history and
`colmena apply --on fredhub` again. The old tokens work again and nothing else
has changed — no content was re-signed, no history rewritten.

## Procedure C: rebuild attic from nothing

Use when fredhub has been replaced and there is no attic server. This is the
one with a step that is easy to miss and silently breaks the whole fleet.

Start by doing the first half of Procedure B: generate a signing key, put it in
sops as `atticd_env`, and `colmena apply --on fredhub`. atticd's first run
creates its database.

Mint a short-lived admin token — this one needs `create-cache`, which the
long-lived tokens deliberately do not have:

```sh
sudo atticd-atticadm make-token --validity "1h" --sub "bootstrap" \
  --push "*" --pull "*" --create-cache "*" --configure-cache "*"
```

Create the cache and make it public, on fredhub as root:

```sh
attic login local http://localhost:8080 "<bootstrap token>"
attic cache create fred
attic cache configure fred --public
```

**Now the step everything depends on.** The new cache generated a new NAR
signing keypair, so the public key in `modules/base/system.nix` is stale. Read
the new one:

```sh
attic cache info fred
```

It prints, among other fields:

```text
           Public Key: fred:JjyhvRSvKfkk8r4HS0mS5r5I7dT4GociEFbrR9OgBZ0=
```

Replace the `fred:...` entry in `trusted-public-keys` in
`modules/base/system.nix` with it. **Skip this and every machine silently
rejects everything the cache serves**, because signatures no longer verify.
There is no error that names the cause; builds just quietly fall back to
upstream and get slow.

Deploy in this order. It matters:

```sh
sudo nixos-rebuild switch --flake .#maranello   # the builder, first
colmena apply                                   # then everything else
```

maranello goes first because `buildOnTarget = false` in
`flake/deployment/colmena.nix` — colmena builds on the deployer, so maranello's
`/etc/nix/nix.conf` is the only one that governs what the fleet build can
substitute. A stale key there affects every host it deploys.

Finally run Procedure A to mint the real `desktop` and `ci` tokens.

The cache starts empty. That is fine and self-correcting: the first builds pull
from `cache.nixos.org`, and CI and the desktops refill it as they push. It also
means the stale-key window is harmless in practice, because there is no content
to reject while the key is wrong.

## Verifying a change

```sh
# anonymous pull still works. Plaintext on purpose -- this is the substituter
# path, and it is the one thing that must not depend on DNS or a certificate.
curl -s -o /dev/null -w '%{http_code}\n' \
  http://192.168.31.14:8080/fred/nix-cache-info          # expect 200

# push works from a desktop
attic push fred /run/current-system

# no token in tracked content. The --exclude matters: this file contains the
# search pattern itself, so without it the check always reports a hit.
grep -rn "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9" \
  --exclude-dir=.git --exclude=ATTIC_OPERATIONS.md .
```

Then trigger any workflow with a push step and confirm it succeeds.

### Proving an old token is dead

After Procedure B or C only. This needs its own section because the obvious
check does not work.

`/fred/nix-cache-info` cannot prove anything: an unverifiable signature makes
the request **anonymous** rather than an error (see `Read this first`), and
anonymous already has pull on a public cache, so that endpoint returns 200 both
before and after a rotation. The check has to use an endpoint that requires a
permission anonymous does not have.

`POST /_api/v1/get-missing-paths` is the one to use. It `require_push()`es, it
mutates nothing, and it is the same call `attic push` makes first — so a 403
here is exactly the failure a real push would hit:

```sh
hash=$(readlink -f /run/current-system | sed 's|^/nix/store/||; s|-.*$||')
body="{\"cache\":\"fred\",\"store_path_hashes\":[\"$hash\"]}"

probe() {
  curl -s -o /dev/null -w '%{http_code}\n' -X POST \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $1" \
    --data "$body" \
    https://attic.int.fredsystems.org/_api/v1/get-missing-paths
}

probe "<OLD_TOKEN>"   # expect 403 -- revoked, so treated as anonymous
probe "<NEW_TOKEN>"   # expect 200 -- the control: proves the probe itself works
```

Run both. A 403 on its own is ambiguous — a typo'd cache name gives 404 and
malformed JSON gives 400, but a mis-copied *token* also gives 403, so without
the second call you cannot tell a successful rotation from a broken probe.

Note the HTTPS endpoint, not `192.168.31.14:8080`. Sending a token you are
trying to prove is dead over plaintext is pointless if it turns out to be
alive.

## Invariants

- **One year, not twelve.** A leak should be a scheduled event, not a crisis.
- **No token in tracked content, ever.** CI reads `secrets.ATTIC_TOKEN`; the
  desktops read sops. Both were committed in plaintext once; that is what
  Procedure B exists to undo.
- **Least privilege.** The long-lived tokens carry `--push` and `--pull` on
  `fred` and nothing else. Cache creation, configuration and destruction happen
  on fredhub with `atticd-atticadm`, where they need no standing credential.
- **The fleet gets no token.** Servers and Macs pull anonymously.
- **`modules/base/system.nix` is the source of truth** for substituters and
  trusted keys. `flake.nix`'s `nixConfig` is a best-effort supplement: it is
  additive rather than overriding, subject to a per-user, per-machine acceptance
  keyed on the literal value, and CI ignores it entirely — every run logs
  `ignoring untrusted flake configuration setting`. Never let it be the only
  place a key lives.
- **Plaintext HTTP on the LAN is for anonymous reads only.** The substituter
  stays on `http://192.168.31.14:8080/fred`: content is signature-verified, so a
  MITM cannot inject anything Nix accepts, and that path needs no DNS,
  certificate or nginx — which is what you want when the host being rebuilt from
  the cache is the cache. Anything carrying a bearer token goes over
  `https://attic.int.fredsystems.org`, which terminates TLS on fredhub itself
  (see `hosts/linux/fredhub/nginx.nix`). That covers `attic push`, `attic login`
  and the `_api/v1` calls in the verification section above. Never send a token
  to port 8080.
