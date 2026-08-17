#!/usr/bin/env bash
#
# check-sops-recipients.sh -- verify sops age-recipient consistency for
# modules/secrets/secrets.yaml across all three places that must agree.
#
# WHY THIS EXISTS
#
# modules/secrets/.sops.yaml declares 12 age recipients under `keys:` and
# wires all of them into a single `creation_rules` entry for secrets.yaml,
# so every one of the 12 machines can decrypt it. Adding a recipient (new
# host, key rotation) requires a manual follow-up step -- `sops updatekeys
# secrets.yaml` -- documented only as a comment in modules/secrets/sops.nix.
# Nothing enforced it. Miss it and the new/rotated host fails to decrypt at
# deploy time, on real hardware, instead of at review time.
#
# KEY INSIGHT
#
# sops embeds the recipient list it actually encrypted for in the ciphertext
# file's own (unencrypted) metadata -- `sops.age[].recipient` in
# secrets.yaml. No decryption key is needed to read it. That means this
# check can run anywhere, including CI runners with no access to any of the
# 12 private keys.
#
# THREE SETS THAT MUST BE EQUAL
#
#   1. anchors    -- the age keys declared under `keys:` in .sops.yaml
#   2. rule       -- the age keys actually referenced by .sops.yaml's
#                    creation_rules entry for `secrets.yaml$`
#   3. embedded   -- the recipients sops actually encrypted secrets.yaml
#                    for, per the file's own metadata
#
# (1 vs 2) catches .sops.yaml itself drifting internally: an anchor added
# or removed from `keys:` without updating the creation_rules key_groups
# that reference it.
#
# (2 vs 3) catches the missed-runbook-step case: creation_rules was
# updated correctly, but `sops updatekeys` was never run, so the file on
# disk still only decrypts for the old recipient set.
set -euo pipefail

# Located by BASH_SOURCE, not `git rev-parse`, so this also works from
# inside the standalone flake check's sandboxed build (no .git there).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SOPS_YAML="modules/secrets/.sops.yaml"
SECRETS_YAML="modules/secrets/secrets.yaml"
RULE_PATH_REGEX="secrets.yaml\$"

# Fail on a missing tool with an actionable message rather than letting the
# first pipeline die on `yq: command not found`. Matches the preamble in
# gen-fleet-manifest.sh and check-colmena-parity.sh. The flake check and the
# pre-commit hook both supply these via runtimeInputs; a human running this
# bare needs `nix develop`.
for tool in yq jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "error: required tool not on PATH: $tool" >&2
    echo "hint: run inside 'nix develop', or via 'nix build .#checks.\${system}.sops-recipients'" >&2
    exit 1
  }
done

for f in "$SOPS_YAML" "$SECRETS_YAML"; do
  if [[ ! -f $f ]]; then
    echo "error: $f not found (run from the repository root)" >&2
    exit 1
  fi
done

# name -> age key, as declared under `keys:`. Falls back to the raw key as
# its own "name" if an entry has no YAML anchor (shouldn't happen here, but
# keeps error messages readable instead of crashing).
anchors_json="$(
  yq -o=json '[.keys[] | {"name": (anchor // .), "key": .}]' "$SOPS_YAML"
)"

# age keys wired into the secrets.yaml$ creation rule, across every
# key_group (sops OR-groups for Shamir secret sharing; only one group
# exists today, but a stray second group must be covered too).
rule_keys_json="$(
  yq -o=json '
    [
      .creation_rules[]
      | select(.path_regex == "'"$RULE_PATH_REGEX"'")
      | .key_groups[]?.age[]?
    ] | unique
  ' "$SOPS_YAML"
)"

if [[ "$(jq 'length' <<<"$rule_keys_json")" -eq 0 ]]; then
  echo "error: no creation_rules entry for path_regex ${RULE_PATH_REGEX} in ${SOPS_YAML}" >&2
  exit 1
fi

# recipients sops actually encrypted secrets.yaml for, read straight out of
# the file's own (unencrypted) sops metadata. No decryption key needed.
embedded_json="$(
  yq -o=json '[.sops.age[]?.recipient] | unique' "$SECRETS_YAML"
)"

if [[ "$(jq 'length' <<<"$embedded_json")" -eq 0 ]]; then
  echo "error: no sops.age[].recipient entries found in ${SECRETS_YAML}" >&2
  exit 1
fi

messages_json="$(
  jq -n \
    --argjson anchors "$anchors_json" \
    --argjson rule_keys "$rule_keys_json" \
    --argjson embedded "$embedded_json" \
    --arg sops_yaml "$SOPS_YAML" \
    --arg secrets_yaml "$SECRETS_YAML" \
    '
    def name_for($key):
      (($anchors[] | select(.key == $key) | .name) // $key);

    ($anchors | map(.key)) as $anchor_keys
    | ($anchor_keys - $rule_keys) as $missing_from_rule
    | ($rule_keys - $anchor_keys) as $extra_in_rule
    | ($rule_keys - $embedded) as $missing_from_secrets
    | ($embedded - $rule_keys) as $extra_in_secrets
    | (
        ($missing_from_rule | map(
          "\($sops_yaml): \(name_for(.)) has an age key under `keys:` but is not wired into the \($secrets_yaml | ltrimstr("modules/secrets/"))$ creation_rules key_groups -- add it to the age list."
        ))
        + ($extra_in_rule | map(
          "\($sops_yaml): creation_rules for \($secrets_yaml | ltrimstr("modules/secrets/"))$ references \(name_for(.)), which has no matching anchor under `keys:` -- stale entry, remove it or restore the anchor."
        ))
        + ($missing_from_secrets | map(
          "\($secrets_yaml) has not been re-encrypted for \(name_for(.)) yet -- creation_rules lists it but the file'"'"'s sops metadata does not. Run: sops updatekeys \($secrets_yaml)"
        ))
        + ($extra_in_secrets | map(
          "\($secrets_yaml) is still encrypted for \(name_for(.)), which is no longer in creation_rules for \($secrets_yaml | ltrimstr("modules/secrets/"))$ -- remove the recipient and run sops updatekeys, or restore the creation_rules entry if this was accidental."
        ))
      )
    '
)"

if [[ "$(jq 'length' <<<"$messages_json")" -gt 0 ]]; then
  echo "sops recipient consistency FAILED:" >&2
  echo "" >&2
  jq -r '.[] | "  - " + .' <<<"$messages_json" >&2
  echo "" >&2
  echo "See the runbook comment in modules/secrets/sops.nix." >&2
  exit 1
fi

count="$(jq 'length' <<<"$rule_keys_json")"
echo "sops recipient consistency OK (${count} recipients, keys/creation_rules/secrets.yaml agree)"
