# Attic credential rotation

Runbook for replacing the Attic tokens that are currently committed to
this repository. Written 2026-08-06, not yet executed.

This is a procedure document, not a record of work done. Delete it once
the rotation is complete and the invariants at the end have been folded
into `modules/services/attic/attic_server.nix`.

## Why this is needed

Two JWTs are committed in tracked files. Both expire 2038-01-27, so
neither ages out on any useful timescale.

| Token subject | Scope                                                                                             | Lives in                                                               |
| ------------- | ------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| `fred`        | cache `fred`: read, write, configure                                                              | `ci-linux.yaml` (x3), `ci-darwin.yaml` (x2), `cache-flake-inputs.yaml` |
| `fred_root`   | cache `*`: read, write, delete, create-cache, configure-cache, configure-retention, destroy-cache | `modules/services/attic/attic_client.nix`                              |

`fred_root` is the serious one, and it is the one the PR review bots did
_not_ flag. `attic_client.nix` is imported by both `flake/lib/mk-system.nix`
and `flake/lib/mk-darwin-system.nix`, so that token is rendered into
`~/.config/attic/config.toml` on **every machine in the fleet**. It can
destroy any cache on the server.

Both are also transmitted over plaintext HTTP to `192.168.31.14:8080`,
so anyone on the LAN can observe them in flight.

## The constraint that shapes everything

Attic has **no token revocation**. `Token::from_jwt` in `token/src/lib.rs`
is a stateless signature-and-expiry check with no database lookup, and
the strings `revoke`, `revocation` and `jti` appear nowhere in the
upstream repository.

The only way to invalidate a leaked token is to rotate the server's
`ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64`, which invalidates **every**
token at once. Both tokens must therefore be replaced in a single
coordinated cutover. There is no incremental path.

## The fact that makes it cheap

The `fred` cache is public:

```text
$ curl -s -o /dev/null -w '%{http_code}' http://192.168.31.14:8080/fred/nix-cache-info
200
```

Pulls need no credential. `substituters` in `modules/base/system.nix`
carries only the _public_ signing key, and there is no netrc anywhere in
the fleet.

So rotating the JWT secret does not stop a single machine from building.
It breaks exactly two things: CI pushes, and interactive `attic push`.

## What does NOT need doing

- **No NAR re-signing.** The cache signing keypair is separate from the
  JWT secret. Its private half lives in atticd's database and was never
  committed; only the public half (`fred:Jjyhv...`) appears in
  `trusted-public-keys`, which is correct and by design. The ~46 GiB of
  cached content stays valid.
- **No git history rewrite.** The old tokens remain in history forever.
  Rotation is what makes them worthless; rewriting history would not,
  and would break every existing clone and PR.
- **No fleet-wide outage window.** See above: pulls are anonymous.

## Phase 0 - shrink the target

Do this first, because it is the change that stops the problem
recurring.

Since pulls are anonymous, the fleet does not need a token at all, let
alone a cache-destroying one. Remove the `token` line from
`modules/services/attic/attic_client.nix`, keeping the endpoint
definition:

```nix
file.".config/attic/config.toml".text = ''
  default-server = "local"

  [servers.local]
  endpoint = "http://192.168.31.14:8080"
'';
```

Anyone needing to push by hand runs `attic login` once with a token
minted for the occasion. After this, standing credentials are exactly
one: a push-scoped CI token in GitHub Actions secrets.

## Phase 1 - prepare, no outage

Nothing here is deployed, so it can be merged whenever.

1. Rewrite the six workflow occurrences to read the token from a
   secret:

   ```yaml
   - name: Log in to Attic
     run: |
       nix shell --inputs-from . nixpkgs#attic-client --command \
         attic login fred http://192.168.31.14:8080 "$ATTIC_TOKEN"
     env:
       ATTIC_TOKEN: ${{ secrets.ATTIC_TOKEN }}
   ```

   Passing it through `env:` rather than inline keeps it out of the
   rendered command line in logs.

2. Apply the phase 0 change to `attic_client.nix`.

3. Do **not** merge yet if you want a clean cutover -- merging before
   phase 2 leaves CI unable to push (the secret does not exist yet).
   Either merge and accept a red push step until phase 2, or hold the
   branch.

## Phase 2 - cutover

Push access is down from the atticd restart until the Actions secret is
set. Sequence it when CI is idle; it is a few minutes.

1. On fredhub, generate a new RS256 secret and write it into the
   sops-managed `atticd_env`:

   ```sh
   nix run nixpkgs#openssl -- genrsa -traditional 4096 | base64 -w0
   ```

   Put it in the `ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64` entry of the
   sops secret consumed by `services.atticd.environmentFile`.

2. Deploy fredhub and restart atticd. Both old tokens are now dead.

3. Mint the replacement CI token. Note the validity: **1 year, not 12**.

   ```sh
   sudo atticd-atticadm make-token --validity "1y" --sub "ci" \
     --push "fred" --pull "fred" --create-cache "fred"
   ```

4. Store it as the `ATTIC_TOKEN` repository secret, then merge the
   phase 1 branch.

5. Deploy the fleet so the superuser token stops being written to
   every machine.

## Phase 3 - verify

```sh
# anonymous pull still works
curl -s -o /dev/null -w '%{http_code}\n' \
  http://192.168.31.14:8080/fred/nix-cache-info    # expect 200

# the old token is now rejected
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer <OLD_TOKEN>" \
  http://192.168.31.14:8080/fred/nix-cache-info    # expect 401

# no token left in tracked content
grep -rn "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9" --exclude-dir=.git .
```

Then trigger any workflow with a push step and confirm it succeeds.

## Rollback

If the cutover goes wrong, restore the previous `atticd_env` from sops
history and restart atticd. The old tokens work again, and everything
returns to the current state. This is safe precisely because no content
was re-signed and no history was rewritten.

## Invariants to keep afterwards

- Tokens are minted with `--validity "1y"`. The current `12y` in the
  setup comment of `attic_server.nix` is why a leak is a crisis rather
  than a scheduled event.
- No token in tracked content, ever. CI reads `secrets.ATTIC_TOKEN`;
  humans run `attic login` locally.
- The fleet gets no token at all. If a machine needs push access,
  that is a deliberate exception, not the default.
- Plaintext HTTP on the LAN remains an accepted risk. If that changes,
  the endpoint moves behind TLS or a tunnel and every `endpoint =`
  reference updates with it.
