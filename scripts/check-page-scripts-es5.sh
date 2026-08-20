#!/usr/bin/env bash
#
# check-page-scripts-es5.sh -- reject ES6+ syntax in the inline <script>
# blocks of the statically-served landing pages under hosts/*/html/.
#
# WHY THIS EXISTS
#
# hosts/linux/sdrhub/html/index.html is the LCARS landing page, and it is
# deliberately written in ES5. Its own comments say so twice: the page's
# job is to be usable during a DNS/AdGuard outage, on whatever browser is
# to hand, and a SYNTAX error is uniquely bad there because it takes out
# the entire <script> element at parse time -- not just the feature that
# used the offending construct. The page silently loses its search box.
#
# That would be a mild style rule if humans were the only authors. They
# are not: `prettier` runs over this file on every commit via the
# pre-commit hooks, and prettier's default output is ES2017. Any call it
# cannot fit in 80 columns it splits across lines and gives a TRAILING
# COMMA in the argument list:
#
#     say(
#       "index error http " +
#         xhr.status +
#         " enter opens github.com",   <-- ES2017, SyntaxError in ES5
#     );
#
# This is not hypothetical. Adding the repository-jump script introduced
# exactly that, produced by prettier, on a line that had been hand-written
# correctly. Nothing else in the toolchain would have caught it: the file
# is not linted as JavaScript, `nix eval` does not read it, and the page
# renders fine in a current browser. It would have failed only on an old
# one, at the moment the page mattered most.
#
# HOW
#
# Tokenising with esprima rather than grepping. `,)` appears legitimately
# inside string literals and comments on this page, and a regex cannot
# tell those apart from real syntax -- the token stream can, because the
# tokeniser has already consumed strings and comments as single units.
#
# USAGE
#
#   ./scripts/check-page-scripts-es5.sh [file ...]
#
# With no arguments every hosts/*/html/*.html is checked. Requires python3
# with esprima; the flake check and pre-commit hook both supply it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ $# -gt 0 ]]; then
  files=("$@")
else
  mapfile -t files < <(find hosts -type f -path '*/html/*.html' | sort)
fi

if [[ ${#files[@]} -eq 0 ]]; then
  echo "no page HTML found; nothing to check"
  exit 0
fi

python3 - "${files[@]}" <<'PY'
import re
import sys

import esprima

# Token-level signatures of syntax newer than ES5. Each entry is
# (label, predicate over (index, tokens)).
#
# Only SYNTAX is checked, never library calls. `JSON.parse`, `classList`
# and friends are ES5-era APIs whose absence degrades one feature; a
# syntax error kills the whole script element, which is the failure this
# script exists to prevent.
ES6_KEYWORDS = {"let", "const", "class", "yield", "await"}


def violations(tokens):
    found = []
    for i, tok in enumerate(tokens):
        kind, value = tok.type, tok.value
        line = tok.loc.start.line

        if kind == "Punctuator":
            # The prettier hazard: `f(a,)` / `function f(a,)`. A comma
            # directly before a closing paren has no legal ES5 reading.
            if value == "," and i + 1 < len(tokens):
                nxt = tokens[i + 1]
                if nxt.type == "Punctuator" and nxt.value == ")":
                    found.append((line, "trailing comma in an argument list (ES2017)"))
            elif value == "=>":
                found.append((line, "arrow function (ES6)"))
            elif value == "...":
                found.append((line, "spread/rest (ES6)"))
        elif kind == "Keyword" and value in ES6_KEYWORDS:
            found.append((line, f"`{value}` (ES6)"))
        elif kind == "Template":
            found.append((line, "template literal (ES6)"))
    return found


def blocks_of(text):
    """Yields (start_line, source) for each inline <script> body."""
    for match in re.finditer(r"<script>(.*?)</script>", text, re.S):
        start_line = text.count("\n", 0, match.start(1)) + 1
        yield start_line, match.group(1)


failed = False

for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as handle:
        text = handle.read()

    count = 0
    for start_line, source in blocks_of(text):
        count += 1
        try:
            tokens = esprima.tokenize(source, {"loc": True})
        except Exception as error:  # noqa: BLE001 - any parse failure is fatal
            failed = True
            print(f"{path}: script block {count} does not parse: {error}", file=sys.stderr)
            continue

        for line, why in violations(tokens):
            failed = True
            # -1 because the block's first line is the <script> line itself.
            print(f"{path}:{start_line + line - 1}: {why}", file=sys.stderr)

    print(f"    {path}: {count} script block(s) checked")

if failed:
    print(
        "\nThese pages are served during network outages and are ES5 on "
        "purpose; a syntax error costs the whole <script> element, not just "
        "the offending feature. If prettier reformatted a call into a "
        "trailing comma, shorten the call (hoist the argument into a "
        "variable) rather than fighting the formatter.",
        file=sys.stderr,
    )
    sys.exit(1)
PY
