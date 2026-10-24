#!/usr/bin/env bash
#
# check-docker-pin-spacing.sh -- verify that no two image pins in
# modules/data/docker-image-pins.nix sit on adjacent lines.
#
# WHY THIS EXISTS
#
# Renovate opens one PR per container image, frequently a dozen or more
# within a minute of an upstream release burst, each changing exactly one
# line of the pins file from the same base commit. Git's three-way merge
# treats edits to adjacent lines as a conflict even when they change
# different attributes, so with pins on consecutive lines the merge queue
# kept marking bumps UNMERGEABLE as soon as a neighbouring pin landed
# ahead of them -- each one then waiting for a Renovate rebase and a full
# CI re-run, and sometimes colliding again on the way back through.
#
# One unchanged line (blank or comment) between any two pins is enough for
# git to merge independent bumps cleanly. That spacing is trivial to lose
# -- a hand edit, or a formatter change -- and losing it fails silently,
# so it is checked rather than documented.
#
# WHAT COUNTS AS A PIN
#
# The same shape Renovate's custom regex manager in .github/renovate.json5
# matches: a quoted `repo:tag` value with an optional `@sha256:` digest and
# no whitespace, terminated by `";`. The option's `description` string has
# spaces in it and is therefore never counted.
set -euo pipefail

# Located by BASH_SOURCE, not `git rev-parse`, so this also works from
# inside the standalone flake check's sandboxed build (no .git there).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PINS_FILE="modules/data/docker-image-pins.nix"

if [[ ! -f "$PINS_FILE" ]]; then
  echo "error: $PINS_FILE not found (run from the repository root)" >&2
  exit 1
fi

pin_regex='"[^"@[:space:]]+:[^"@[:space:]]+(@sha256:[a-f0-9]+)?";'

status=0
prev_is_pin=0
prev_line=""
lineno=0

while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))

  if [[ "$line" =~ $pin_regex ]]; then
    if ((prev_is_pin)); then
      echo "error: $PINS_FILE:$lineno: pin is adjacent to the pin on line $((lineno - 1))" >&2
      echo "  $((lineno - 1)): ${prev_line#"${prev_line%%[![:space:]]*}"}" >&2
      echo "  $lineno: ${line#"${line%%[![:space:]]*}"}" >&2
      status=1
    fi
    prev_is_pin=1
  else
    prev_is_pin=0
  fi

  prev_line="$line"
done <"$PINS_FILE"

if ((status)); then
  echo "" >&2
  echo "Separate every pin from the next with a blank line (or a comment)." >&2
  echo "Adjacent pins make independent Renovate bumps conflict in the merge" >&2
  echo "queue; see the header of $PINS_FILE." >&2
  exit 1
fi

echo "docker image pins are spaced OK"
