#!/usr/bin/env bash
#
# check-option-schema.sh -- assert that every `mkOption { ... }` call in the
# tree declares both a `type` and a `description`.
#
# WHY THIS EXISTS
#
# An audit of the 86-ish `mkOption` sites in this repo found one option
# with no `type` at all (modules/secrets/sops.nix's
# `sops_secrets.enable_secrets.enable`, since converted to
# `lib.mkEnableOption`) and roughly seventeen with no `description`,
# concentrated in modules/terminal/common.nix, modules/services/nas-*.nix
# and modules/services/sync-compose.nix. Neither omission fails the build:
# an untyped option silently accepts whatever nonsense is assigned to it
# with no coercion/merge behaviour and no eval-time type error, and an
# undocumented option is just as functional as a documented one until
# someone tries to use it and has to go read the defining module instead
# of `nixos-option`/generated docs. Nothing previously stopped a new
# option from being added the same way.
#
# `lib.mkEnableOption "foo"` is intentionally NOT flagged: it expands to an
# option that already carries both a `types.bool` type and a generated
# description ("Whether to enable foo."), so requiring a second explicit
# `type`/`description` on top of it would be busywork, not safety.
#
# PARSING STRATEGY
#
# Regexing `mkOption { ... }` line-by-line breaks the moment a value spans
# multiple lines (every multi-line `description`, every `submodule`, every
# `enum [ ... ]`) or a nested option block reuses the same field names one
# level down. This script instead:
#
#   1. Masks out comments (`#`, `/* */`) and string bodies (`"..."`,
#      `''...''`) to spaces, character-for-character (newlines preserved),
#      so brace-matching below is never confused by a `{`/`}`/`;` that
#      only exists inside a comment or a string. This is safe because Nix
#      string/comment bodies cannot contribute an UNbalanced brace to the
#      surrounding code: any `${...}` antiquotation inside a string is
#      itself brace-balanced, so blanking the whole string only removes
#      balanced pairs.
#   2. Finds every standalone `mkOption` token (word-bounded, so this
#      correctly skips `mkEnableOption` and `mkOptionDefault`, neither of
#      which contains "mkOption" as a bounded substring).
#   3. Requires the next non-whitespace character to be `{`. A bare
#      `mkOption` mention that is NOT immediately followed by an attrset
#      literal (e.g. appearing in an `inherit (lib) mkOption ...;` import
#      list, which this repo has twice) is not a call site at all and is
#      silently skipped -- it is not ambiguous, it is simply not a call.
#   4. Brace-matches from that `{` to find the call's own closing `}`,
#      tracking only `{`/`}` depth (not parens/brackets): Nix has no other
#      use of curly braces, so any `{`/`}` encountered anywhere inside --
#      nested submodule, list-of-attrsets, function call taking an
#      attrset -- still balances correctly against this same counter.
#   5. Within that body, splits on `;` at brace-depth 0 (relative to the
#      body) to recover the body's own top-level `key = value;`
#      assignments, and checks whether `type` and `description` are among
#      them.
#
# KNOWN LIMITATION (documented, not silently swallowed)
#
# Step 5's depth counter tracks only `{`/`}`, so a bare `let x = ...; in
# ...;` used as a value (no enclosing braces) introduces a `;` at
# apparent depth 0 that does not really terminate the enclosing
# assignment. This repo has exactly one such case today
# (modules/data/home-network.nix's `type = let octet = "..."; in
# lib.types.strMatching ...;`), and it happens to still classify
# correctly: the spurious early split still starts with the real `type =`
# token (the first `=` in the mis-split segment), so `type` is still
# recorded; the "orphan" continuation segment (` in lib.types.strMatching
# ...`) contains no top-level `=` and is discarded rather than
# misread as a second, bogus key. This has been verified empirically
# against the current tree. The failure mode this construct COULD in
# theory cause is a false negative -- a `let`-bound local variable that
# happens to be named `type` or `description` could make a genuinely
# undocumented option look documented -- never a false positive. That
# tradeoff (miss a violation vs. block an unrelated commit on a parser
# artifact) is the intended one; see the reachability checker for the
# same philosophy applied to a different check.
#
# `default`/`example`/`apply`/`readOnly`/`internal` and any other
# recognised or unrecognised mkOption field are not inspected; this check
# only asserts presence of `type` and `description`, not their content.
set -euo pipefail

# Located by BASH_SOURCE, not `git rev-parse`, so this also works from
# inside the standalone flake check's sandboxed build (no .git there).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Fail on a missing dependency with an actionable message, kept separate
# from the actual content check below: reporting "python3 is missing" as
# an option-schema violation would invent a bug that does not exist. See
# check-opencode-jsonc.sh for the precedent and the incident that made
# this its own paragraph.
command -v python3 >/dev/null 2>&1 || {
  echo "error: required tool not on PATH: python3" >&2
  echo "hint: run inside 'nix develop', or via 'nix build .#checks.\${system}.option-schema'" >&2
  exit 1
}

python3 - "$REPO_ROOT" <<'PY'
import re
import subprocess
import sys

repo_root = sys.argv[1]

result = subprocess.run(
    ["find", ".", "-name", "*.nix", "-not", "-path", "./.git/*"],
    capture_output=True,
    text=True,
    cwd=repo_root,
    check=True,
)
files = sorted(f for f in result.stdout.split() if f)

if not files:
    print("error: no .nix files found (run from the repository root)", file=sys.stderr)
    sys.exit(1)


def mask(text):
    """Blank out comment and string bodies, preserving length and newlines."""
    out = list(text)
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if text[i : i + 2] == "/*":
            j = text.find("*/", i + 2)
            end = j + 2 if j != -1 else n
            for k in range(i, end):
                if out[k] != "\n":
                    out[k] = " "
            i = end
            continue
        if c == "#":
            j = text.find("\n", i)
            end = j if j != -1 else n
            for k in range(i, end):
                out[k] = " "
            i = end
            continue
        if text[i : i + 2] == "''":
            j = text.find("''", i + 2)
            end = j + 2 if j != -1 else n
            for k in range(i, end):
                if out[k] != "\n":
                    out[k] = " "
            i = end
            continue
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                if text[j] == "\\":
                    j += 1
                j += 1
            end = j + 1 if j < n else n
            for k in range(i, end):
                if out[k] != "\n":
                    out[k] = " "
            i = end
            continue
        i += 1
    return "".join(out)


def find_matching_close(masked, open_pos):
    depth = 1
    i = open_pos + 1
    n = len(masked)
    while i < n and depth > 0:
        if masked[i] == "{":
            depth += 1
        elif masked[i] == "}":
            depth -= 1
        i += 1
    return (i - 1) if depth == 0 else None


_ASSIGN_TARGET_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_'-]*$")


def parse_key(segment):
    """Return the leading attrpath's first component, or None if this
    segment is not (or does not start with) a `key = value` assignment."""
    stripped = segment.strip()
    if not stripped:
        return None
    idx = None
    for m in re.finditer(r"=", stripped):
        pos = m.start()
        prevc = stripped[pos - 1] if pos > 0 else ""
        nextc = stripped[pos + 1] if pos + 1 < len(stripped) else ""
        if nextc == "=" or prevc in "!<>=":
            continue
        idx = pos
        break
    if idx is None:
        return None
    left = stripped[:idx].strip()
    first = left.split(".")[0].strip().strip('"')
    return first if _ASSIGN_TARGET_RE.match(first) else None


def extract_top_level_keys(masked_body):
    keys = []
    depth = 0
    seg_start = 0
    for i, c in enumerate(masked_body):
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
        elif c == ";" and depth == 0:
            key = parse_key(masked_body[seg_start:i])
            if key:
                keys.append(key)
            seg_start = i + 1
    return keys


MKOPTION_RE = re.compile(r"\bmkOption\b")

violations = []
unbalanced = []
total_calls = 0

for relpath in files:
    with open(f"{repo_root}/{relpath}", encoding="utf-8") as fh:
        text = fh.read()
    masked = mask(text)

    for m in MKOPTION_RE.finditer(masked):
        rest = masked[m.end() :]
        skip = len(rest) - len(rest.lstrip())
        brace_pos = m.end() + skip
        if brace_pos >= len(masked) or masked[brace_pos] != "{":
            # Not a call site (e.g. `inherit (lib) mkOption ...;`).
            continue

        total_calls += 1
        line_no = text[: m.start()].count("\n") + 1
        close_pos = find_matching_close(masked, brace_pos)
        if close_pos is None:
            unbalanced.append(f"{relpath}:{line_no}: mkOption {{ ... }} has no matching closing brace (unbalanced braces, or a construct this script cannot classify)")
            continue

        body = masked[brace_pos + 1 : close_pos]
        keys = extract_top_level_keys(body)

        missing = [f for f in ("type", "description") if f not in keys]
        if missing:
            violations.append(f"{relpath}:{line_no}: mkOption is missing {', '.join(missing)}")

if unbalanced:
    print("option schema check FAILED (could not parse):", file=sys.stderr)
    print("", file=sys.stderr)
    for u in unbalanced:
        print(f"  - {u}", file=sys.stderr)
    sys.exit(1)

if violations:
    print("option schema check FAILED:", file=sys.stderr)
    print("", file=sys.stderr)
    for v in sorted(violations):
        print(f"  - {v}", file=sys.stderr)
    print("", file=sys.stderr)
    print("Every mkOption { ... } needs a `type` (so a bad value is an eval error,", file=sys.stderr)
    print("not a silent no-op) and a `description` (so the option is discoverable", file=sys.stderr)
    print("without reading the defining module). `lib.mkEnableOption \"foo\"` already", file=sys.stderr)
    print("supplies both and does not need either field added.", file=sys.stderr)
    sys.exit(1)

print(f"option schema OK ({total_calls} mkOption call sites, all with type + description)")
PY
