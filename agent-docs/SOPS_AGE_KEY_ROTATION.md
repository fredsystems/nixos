# sops age-key rotation

Runbook for adding, removing, and verifying age recipients for
`modules/secrets/secrets.yaml`. This is the credential that gates every
other secret in the fleet, so getting recipient changes wrong is worse
than getting most other rotations wrong: a mistake here can either
silently lock a host out of its own secrets at deploy time, or leave a
removed recipient able to decrypt long after you believe they cannot.

## Read this first

`modules/secrets/.sops.yaml` declares 12 age recipients as YAML anchors
under `keys:` and wires all 12 into a single `creation_rules` entry for
`secrets.yaml$`. Every host that needs any secret from this file must be
in that list -- there is no per-secret recipient scoping, only
per-file.

**Three sets have to agree, and `scripts/check-sops-recipients.sh`
exists because nothing used to check that they did:**

1. the anchors declared under `keys:` in `.sops.yaml`
2. the age keys actually referenced by the `creation_rules` entry for
   `secrets.yaml$`
3. the recipients sops actually encrypted `secrets.yaml` for, per the
   file's own (unencrypted) `sops.age[].recipient` metadata

(1) and (2) can drift from each other by editing `.sops.yaml` alone.
(2) and (3) drift when `.sops.yaml` is updated correctly but `sops
updatekeys` is never run -- the file on disk still only decrypts for
the old set. Every procedure below ends by running that script, and so
does the `sops-recipients` flake check (`nix build
.#checks.<system>.sops-recipients`), which runs the same script in CI
and in the pre-commit hook whenever `.sops.yaml` or `secrets.yaml`
changes.

**`sops updatekeys` and `sops rotate` do different things, and only one
of them actually revokes access.** This is the fact the inline comment
in `sops.nix` did not capture, and it is the reason removing a
recipient needs its own procedure instead of being the reverse of
adding one:

- `sops updatekeys` reconciles *who holds a wrapped copy of the current
  data encryption key (DEK)*, against `creation_rules`. It adds a
  wrapped DEK for a new recipient and drops the wrapped DEK entry for a
  removed one. **It does not change the DEK itself.** Every value in
  the file is still encrypted with the same DEK it was encrypted with
  before.
- `sops rotate` generates a **brand-new** DEK and re-encrypts every
  value in the file with it, then wraps that new DEK for whoever is
  currently a recipient.

The distinction matters for revocation: a host that had legitimate
decrypt access could have extracted the plaintext DEK before being
removed (not just its own wrapped copy of it). Running `updatekeys`
alone drops that host's entry from the file, but the surviving
ciphertext is still encrypted with the same DEK that host already
extracted -- so if it retained an old copy of the file, or the actual
DEK value, `updatekeys` alone has not revoked anything. Only `sops
rotate`, run *after* the recipient is removed from `.sops.yaml`, puts
the remaining secrets behind a DEK that host was never given. This is
the same "no partial revocation, only wholesale key replacement"
property `ATTIC_OPERATIONS.md`'s Procedure B documents for the JWT
signing key, except here sops gives you the tool to do it
(`rotate`) instead of you having to regenerate and redeploy the whole
service.

**Editing `.sops.yaml` is destructive to itself if done in two steps.**
The `creation_rules` age list references `keys:` anchors by YAML alias
(`*name`). If you remove an anchor from `keys:` and commit that alone,
without also removing its alias from `creation_rules`, the file no
longer parses -- every `sops` invocation against it fails immediately,
for every recipient, not just the one you touched. Add or remove the
anchor and its `creation_rules` reference in the same edit.

## Procedure A: add a new recipient (new host)

Use when bringing up a new host that needs any secret from
`secrets.yaml`.

1. Generate an age keypair on the new host, if `add_new_system_sop.sh`
   has not already been run there:

   ```sh
   nix shell nixpkgs#age -c age-keygen -o ~/.config/sops/age/keys.txt
   ```

   The command prints the public key (`age1...`) — copy it.

2. On a machine that can already decrypt `secrets.yaml` (e.g.
   maranello), add the new host as an anchor under `keys:` and add that
   anchor to the `creation_rules` age list for `secrets.yaml$`, in the
   same edit:

   ```sh
   cd ~/GitHub/nixos
   "$EDITOR" modules/secrets/.sops.yaml
   ```

3. Re-encrypt `secrets.yaml` for the new recipient set. sops shows a
   diff of who is being added/removed and asks for confirmation; `-y`
   skips the prompt for non-interactive use:

   ```sh
   sops updatekeys modules/secrets/secrets.yaml
   ```

4. Verify all three sets agree:

   ```sh
   bash scripts/check-sops-recipients.sh
   ```

5. Commit `.sops.yaml` and `secrets.yaml` together — a commit touching
   only one of the two is exactly the drift the check above exists to
   catch:

   ```sh
   git add modules/secrets/.sops.yaml modules/secrets/secrets.yaml
   git commit
   ```

6. Deploy the new host and confirm it actually decrypted (the metadata
   check in step 4 proves sops *intends* the host to be able to
   decrypt; it does not prove the host's own key file matches):

   ```sh
   ssh <newhost> 'test -s /run/secrets/fred-gpg && echo OK'
   ```

   Pick any secret the new host's config actually declares in its
   `sops.secrets` block — `fred-gpg` is the one every Linux host with
   `sops_secrets.enable_secrets.enable = true` gets via
   `modules/secrets/sops.nix`.

## Procedure B: remove a compromised recipient

Use when a host's age private key is suspected leaked. This is the
crisis response — the one to reach for, not the add-in-reverse.

Everything currently in `secrets.yaml` must be treated as already seen
by whoever has the compromised key. This procedure stops *future*
exposure; it does not undo the past one. If any individual secret's
own *value* (not just sops's ability to decrypt it) may have been
read and copied out, that secret's own credential must be rotated too
— see `GRAFANA_SECRET_KEY_ROTATION.md` and `ATTIC_OPERATIONS.md`'s
Procedure B for the two that have their own runbooks; anything else in
`secrets.yaml` needs the same treatment on a case-by-case basis.

1. Remove the compromised host's anchor from `keys:` **and** its alias
   from the `creation_rules` age list, in the same edit (see "Read this
   first" — leaving these out of sync breaks the file for everyone):

   ```sh
   cd ~/GitHub/nixos
   "$EDITOR" modules/secrets/.sops.yaml
   ```

2. Drop the compromised host's wrapped DEK entry from the file:

   ```sh
   sops updatekeys modules/secrets/secrets.yaml
   ```

3. **Rotate the DEK itself.** This is the step that actually revokes
   access — skipping it leaves every value encrypted with a key the
   compromised host may already have extracted:

   ```sh
   sops rotate --in-place modules/secrets/secrets.yaml
   ```

4. Verify the file is now wrapped for exactly the remaining recipients
   and no more:

   ```sh
   bash scripts/check-sops-recipients.sh
   ```

5. Commit `.sops.yaml` and `secrets.yaml` together:

   ```sh
   git add modules/secrets/.sops.yaml modules/secrets/secrets.yaml
   git commit
   ```

6. Redeploy every remaining host, not just one — `secrets.yaml` is
   shared, and every host re-decrypts it on its next activation
   regardless of whether that host's own secrets changed:

   ```sh
   colmena apply                                   # servers
   sudo nixos-rebuild switch --flake .#maranello   # desktops, locally
   sudo nixos-rebuild switch --flake .#Daytona
   darwin-rebuild switch --flake .#Freds-MacBook-Pro   # Darwin, locally
   darwin-rebuild switch --flake .#Freds-Mac-Studio
   ```

7. If the compromised host is being decommissioned rather than
   re-keyed, that is a separate exercise (remove it from
   `flake/hosts/servers.nix`, the colmena topology, monitoring targets,
   etc.) — out of scope here.

If you need to re-admit the same physical host later, treat it as a
brand-new host: generate a fresh age keypair (Procedure A, step 1) and
add it back under a fresh anchor. Never re-add the compromised public
key.

## Verifying every one of the 12 recipients can still decrypt

The automated check only proves the *metadata* is internally
consistent — that sops *intends* exactly these recipients to be able to
decrypt. It cannot prove a given host's key file on disk still matches,
so both steps below are required after any recipient change, not just
one.

1. Run the three-way check:

   ```sh
   bash scripts/check-sops-recipients.sh
   ```

   Expect:

   ```text
   sops recipient consistency OK (12 recipients, keys/creation_rules/secrets.yaml agree)
   ```

   A count other than the number of recipients you expect, or a
   non-zero exit, means stop here — do not proceed to redeploying the
   fleet with a `secrets.yaml` that does not match `.sops.yaml`.

2. Confirm actual decryption on every host that should still have
   access. Run this from each host, not against a copy of the repo
   elsewhere — the whole point is testing that host's own key file:

   ```sh
   for host in maranello Daytona acarshub hfdlhub1 hfdlhub2 sdrhub \
     vdlmhub fredhub nvrhub; do
     echo "== $host =="
     ssh "$host" 'cd ~/GitHub/nixos && sops -d modules/secrets/secrets.yaml >/dev/null && echo OK'
   done

   # fredvps uses a non-standard SSH port and a different target host --
   # see flake/hosts/servers.nix
   ssh -p 2269 fredclausen.com \
     'cd ~/GitHub/nixos && sops -d modules/secrets/secrets.yaml >/dev/null && echo OK'
   ```

   The two Darwin hosts (`Freds-MacBook-Pro`, `Freds-Mac-Studio`) are
   often offline or unreachable over SSH; run the same `sops -d ... &&
   echo OK` check locally on each the next time it is available, rather
   than skipping it. Do not consider a recipient-set change fully
   verified until all 12 have reported `OK` at least once since the
   change.

## Invariants

- **One file, one recipient list.** There is no per-secret scoping
  inside `secrets.yaml` — anyone in the recipient list can decrypt
  everything in it.
- **`.sops.yaml` and `secrets.yaml` change together, in the same
  commit.** A commit that edits one without the other is the exact
  drift `check-sops-recipients.sh` exists to catch.
- **Removing a recipient means rotating the DEK, not just editing the
  recipient list.** `sops updatekeys` alone does not revoke anything —
  see "Read this first".
- **The three-way check is necessary but not sufficient.** It proves
  the metadata is self-consistent; only an actual per-host decrypt
  proves the corresponding private key still works.
