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
# HOW -- TWO PASSES, ON PURPOSE
#
# 1. An esprima token scan, for DIAGNOSTICS. It names the construct and
#    the standard it came from. eslint reports the trailing-comma case as
#    "Unexpected token )", which points at the paren when the problem is
#    the comma; this pass is what makes the failure actionable.
#
# 2. eslint with `ecmaVersion: 5`, as the AUTHORITATIVE gate. It is a real
#    ES5 grammar, so it rejects everything -- generators, default
#    parameters, destructuring, for...of, shorthand methods -- and not
#    merely the constructs someone thought to list.
#
# The token scan cannot be the gate, because a blocklist is only ever as
# complete as its author. eslint alone would be a worse tool to be on the
# receiving end of. So both run, and both must pass.
#
# Tokenising rather than grepping, in either case: `,)` appears
# legitimately inside string literals and comments on this page, and a
# regex cannot tell those from real syntax. A token stream can, because
# the tokeniser has already consumed strings and comments as single units.
#
# USAGE
#
#   ./scripts/check-page-scripts-es5.sh [file ...]
#
# With no arguments every hosts/*/html/*.html is checked. Requires python3
# with esprima, and eslint; the flake check and pre-commit hook supply both.
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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- pass 1
# Token scan for named diagnostics. Also extracts each block to disk so
# pass 2 has something to parse, and records the line offset needed to map
# eslint's block-relative numbers back onto the HTML file.
token_status=0
python3 - "$WORK" "${files[@]}" <<'TOKENSCAN' || token_status=1
import json
import re
import sys
from pathlib import Path

import esprima

# Token-level signatures of syntax newer than ES5.
#
# Only SYNTAX is checked, never library calls. `JSON.parse`, `classList`
# and friends are ES5-era APIs whose absence degrades one feature; a
# syntax error kills the whole script element, which is the failure this
# script exists to prevent.
#
# `import`/`export` are ES5 FutureReservedWords that became real syntax in
# ES6, so an ES5 engine rejects them outright.
ES6_KEYWORDS = {
    "await",
    "class",
    "const",
    "export",
    "import",
    "let",
    "yield",
}


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


work = Path(sys.argv[1])
manifest = []
failed = False

for path in sys.argv[2:]:
    text = Path(path).read_text(encoding="utf-8")

    count = 0
    for start_line, source in blocks_of(text):
        count += 1
        extracted = work / f"{Path(path).name}.{count}.js"
        extracted.write_text(source, encoding="utf-8")
        # -1 because the block's first line is the <script> line itself.
        manifest.append(
            {"js": str(extracted), "html": path, "offset": start_line - 1}
        )

        try:
            tokens = esprima.tokenize(source, {"loc": True})
        except Exception as error:  # noqa: BLE001 - any parse failure is fatal
            failed = True
            print(
                f"{path}: script block {count} does not tokenise: {error}",
                file=sys.stderr,
            )
            continue

        for line, why in violations(tokens):
            failed = True
            print(f"{path}:{start_line + line - 1}: {why}", file=sys.stderr)

    print(f"    {path}: {count} script block(s) checked")

(work / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
sys.exit(1 if failed else 0)
TOKENSCAN

# ---------------------------------------------------------------- pass 2
# --no-config-lookup so a stray eslint config elsewhere in the tree cannot
# change the answer. No plugins and no rules are configured, so the run is
# hermetic and works inside a sandboxed Nix build with no network; the only
# messages it can emit are parse errors against the ES5 grammar.
cat > "$WORK/eslint.config.mjs" <<'ESLINTCFG'
export default [
  {
    files: ["**/*.js"],
    languageOptions: { ecmaVersion: 5, sourceType: "script" },
    rules: {},
  },
];
ESLINTCFG

# nullglob and an explicit array rather than `compgen -G`: compgen is not
# present in every bash build (it is absent from the one the pre-commit
# hook runs under), and there it failed the `if` and skipped this entire
# pass while the script still exited 0 -- silently disabling the
# authoritative gate, which is the exact failure mode this file exists to
# prevent.
shopt -s nullglob
extracted=("$WORK"/*.js)
shopt -u nullglob

# Pass 1 records one manifest entry per extracted block, so a mismatch here
# means blocks went missing between the passes. Fail loudly rather than
# quietly checking nothing.
expected="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$WORK/manifest.json")"
if [[ ${#extracted[@]} -ne $expected ]]; then
  echo "error: extracted ${#extracted[@]} script block(s) but the manifest lists $expected" >&2
  exit 1
fi

grammar_status=0
if [[ ${#extracted[@]} -gt 0 ]]; then
  # eslint exits non-zero when it finds anything, which is not an error
  # here -- the report is parsed either way.
  # Run from inside $WORK: eslint refuses files outside its config's base
  # path, reporting them as "File ignored because outside of base path"
  # rather than parsing them.
  (
    cd "$WORK"
    eslint --no-config-lookup --config eslint.config.mjs --format json ./*.js
  ) > "$WORK/eslint.json" 2> "$WORK/eslint.err" || true

  python3 - "$WORK" <<'MAPREPORT' || grammar_status=1
import json
import sys
from pathlib import Path

work = Path(sys.argv[1])
report = work / "eslint.json"

if not report.exists() or not report.read_text().strip():
    print("error: eslint produced no report", file=sys.stderr)
    print((work / "eslint.err").read_text(encoding="utf-8"), file=sys.stderr)
    sys.exit(1)

# Keyed on basename, not the full path: eslint resolves and normalises
# what it is given, so the strings need not come back byte-identical.
offsets = {
    Path(m["js"]).name: m
    for m in json.loads((work / "manifest.json").read_text())
}
failed = False

for result in json.loads(report.read_text()):
    entry = offsets.get(Path(result["filePath"]).name)
    for message in result.get("messages", []):
        failed = True
        line = message.get("line", 0)
        where = (
            f"{entry['html']}:{entry['offset'] + line}"
            if entry
            else result["filePath"]
        )
        print(f"{where}: {message.get('message')} [es5 grammar]", file=sys.stderr)

sys.exit(1 if failed else 0)
MAPREPORT
fi

if [[ $token_status -ne 0 || $grammar_status -ne 0 ]]; then
  cat >&2 <<'GUIDANCE'

These pages are served during network outages and are ES5 on purpose; a
syntax error costs the whole <script> element, not just the offending
feature. If prettier reformatted a call into a trailing comma, shorten the
call (hoist the argument into a variable) rather than fighting the
formatter.
GUIDANCE
  exit 1
fi
