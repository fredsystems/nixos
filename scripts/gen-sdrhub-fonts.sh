#!/usr/bin/env bash
#
# gen-sdrhub-fonts.sh -- regenerate the subsetted web fonts served by
# sdrhub's landing page (hosts/linux/sdrhub/html/).
#
# WHY THESE FONTS ARE COMMITTED RATHER THAN BUILT
#
# The landing page's whole job is to be reachable when the network is
# broken. The comment block above `migratedVhosts` in
# hosts/linux/sdrhub/configuration.nix documents this page as part of the
# escape hatch for a DNS/AdGuard fault -- and during exactly that fault a
# CDN does not resolve, so the previous `cdnjs.cloudflare.com` Font Awesome
# link rendered a page with no icons. Everything must therefore be local.
#
# "Local" could mean either committed bytes or a `runCommand` that subsets
# at build time. Committed bytes won for one reason: `pkgs.google-fonts` is
# a 2.3 GB derivation. Referencing it from a build step would drag that
# into the build closure of every sdrhub evaluation to extract 16 KB of
# Antonio, and CI would have to substitute it. The fonts change roughly
# never, so paying that cost on every build to avoid committing 52 KB is
# the wrong trade.
#
# This script exists so the committed bytes are reproducible and their
# provenance is recorded, rather than being mystery binaries someone
# generated once by hand.
#
# WHY SUBSETTED
#
# The upstream faces total ~1.5 MB (Font Awesome Solid alone is 414 KB) and
# the page uses 26 icons and ASCII text. Subsetting to the codepoints
# actually referenced takes that to ~52 KB, which also keeps each file well
# under the `check-added-large-files --maxkb=600` pre-commit hook.
#
# The Unicode ranges below are deliberately narrow. If you add an icon to
# index.html you MUST add its codepoint to FA_SOLID_CP (or FA_BRANDS_CP)
# and re-run this script, or the glyph will silently render as a blank box.
#
# CODEPOINT SELECTION -- PRIVATE USE AREA, NOT EMOJI
#
# Font Awesome 7 maps many icons to BOTH a private-use codepoint and the
# real Unicode emoji codepoint (`bell` is at U+F0A2 and U+1F514; `film` at
# U+F008 and U+1F39E). The emoji codepoints are a trap: a browser is free
# to satisfy U+1F514 from a colour emoji font in its fallback chain and
# render an emoji instead of the icon. Every codepoint below is therefore
# the private-use one.
#
# USAGE
#
#   ./scripts/gen-sdrhub-fonts.sh
#
# Requires `nix` on PATH; it fetches fonttools/brotli itself. Re-running
# with unchanged inputs is byte-for-byte idempotent (pyftsubset output is
# deterministic), so a no-op run leaves the git tree clean.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OUT_DIR="hosts/linux/sdrhub/html/fonts"

command -v nix >/dev/null 2>&1 || {
  echo "error: nix is required but not on PATH" >&2
  exit 1
}

# Icons used by index.html, as Font Awesome 7 *private-use* codepoints.
# Keep this list sorted and in sync with the page. See the header comment
# for why these are not the emoji codepoints.
#
#   e22d plane-up                  (nav: aviation)
#   e4e2 circle-nodes              (combined tar1090)
#   f002 magnifying-glass          (search)
#   f008 film                      (jellyfin / nav: media)
#   f012 signal                    (dump978)
#   f03d video                     (frigate nvr)
#   f0a0 hard-drive                (rackstation)
#   f0a2 bell                      (karma)
#   f0ac globe                     (nav: external, acarshub.app)
#   f1c0 database                  (prometheus)
#   f1fe chart-area                (graphs1090)
#   f201 chart-line                (grafana)
#   f233 server                    (nav: infra)
#   f3ed shield-halved             (adguard)
#   f519 tower-broadcast           (page mark)
#   f544 robot                     (ai, local)
#   f57d earth-americas            (flightradar24)
#   f5a0 map-location-dot          (tar1090)
#   f5dc brain                     (ai, fredhub)
#   f625 gauge-high                (nav: monitoring)
#   f658 envelope-open-text        (acars hub)
#   f689 magnifying-glass-location (plane finder)
FA_SOLID_CP="e22d,e4e2,f002,f008,f012,f03d,f0a0,f0a2,f0ac,f1c0,f1fe,f201,f233,f3ed,f519,f544,f57d,f5a0,f5dc,f625,f658,f689"

# Brand marks, from the Brands face rather than Solid.
#   f395 docker       (dozzle)
#   f7bb raspberry-pi (piaware)
FA_BRANDS_CP="f395,f7bb"

# Printable ASCII, plus U+00B7 MIDDLE DOT (used as a separator throughout
# the page) and U+2019 RIGHT SINGLE QUOTATION MARK (the apostrophe in
# "Fred's"). Antonio is display-only here; JetBrains Mono needs no
# apostrophe.
TEXT_CP="U+0020-007E,U+00B7,U+2019"
MONO_CP="U+0020-007E,U+00B7"

echo "==> resolving upstream font packages"
FA_DIR="$(nix build --no-link --print-out-paths nixpkgs#font-awesome)/share/fonts/opentype"
GF_DIR="$(nix build --no-link --print-out-paths nixpkgs#google-fonts)/share/fonts/truetype"

for f in "$FA_DIR/Font Awesome 7 Free-Solid-900.otf" \
  "$FA_DIR/Font Awesome 7 Brands-Regular-400.otf" \
  "$GF_DIR/Antonio[wght].ttf" \
  "$GF_DIR/JetBrainsMono[wght].ttf"; do
  [[ -f $f ]] || {
    echo "error: expected font not found: $f" >&2
    echo "hint: upstream may have renamed it; check the package contents" >&2
    exit 1
  }
done

mkdir -p "$OUT_DIR"

# Resolved once and then invoked by absolute path. Running the subsetting
# inside `nix shell --command bash -c '...'` would mean a single-quoted
# script body -- which cannot reference the variables above, so every path
# would have to be smuggled in as a positional parameter (and shellcheck
# rightly flags the result as SC2016). Building the environment and calling
# its binaries directly keeps everything in one scope.
PY_ENV="$(nix build --no-link --print-out-paths --impure --expr \
  'with import <nixpkgs> {}; python3.withPackages (ps: [ ps.fonttools ps.brotli ])')"

echo "==> subsetting"

# --no-hinting: hinting instructions are dead weight for a font that is only
# ever rendered by a browser doing its own grid-fitting.
# --desubroutinize: CFF subroutines can outweigh the glyphs they encode at
# these tiny subset sizes.
"$PY_ENV/bin/pyftsubset" "$FA_DIR/Font Awesome 7 Free-Solid-900.otf" \
  --unicodes="$FA_SOLID_CP" --flavor=woff2 --no-hinting --desubroutinize \
  --output-file="$OUT_DIR/fa-solid.woff2"

"$PY_ENV/bin/pyftsubset" "$FA_DIR/Font Awesome 7 Brands-Regular-400.otf" \
  --unicodes="$FA_BRANDS_CP" --flavor=woff2 --no-hinting --desubroutinize \
  --output-file="$OUT_DIR/fa-brands.woff2"

# Antonio and JetBrains Mono are variable fonts. The page uses a range of
# weights from each, so the wght axis is kept rather than pinned.
"$PY_ENV/bin/pyftsubset" "$GF_DIR/Antonio[wght].ttf" \
  --unicodes="$TEXT_CP" --flavor=woff2 --no-hinting \
  --output-file="$OUT_DIR/antonio.woff2"

"$PY_ENV/bin/pyftsubset" "$GF_DIR/JetBrainsMono[wght].ttf" \
  --unicodes="$MONO_CP" --flavor=woff2 --no-hinting \
  --output-file="$OUT_DIR/jetbrains-mono.woff2"

echo "==> verifying every referenced codepoint survived subsetting"
# A subset that silently dropped a glyph renders as a blank box in the
# browser and nowhere else, so this is checked rather than assumed.
"$PY_ENV/bin/python3" - "$OUT_DIR" "$FA_SOLID_CP" "$FA_BRANDS_CP" <<'PY'
import sys
from fontTools.ttLib import TTFont

out_dir, solid_cp, brands_cp = sys.argv[1], sys.argv[2], sys.argv[3]
failed = False

for fname, cps in (("fa-solid.woff2", solid_cp), ("fa-brands.woff2", brands_cp)):
    path = f"{out_dir}/{fname}"
    cmap = TTFont(path).getBestCmap()
    missing = [c for c in cps.split(",") if int(c, 16) not in cmap]
    if missing:
        failed = True
        print(f"error: {fname} is missing codepoints: {missing}", file=sys.stderr)
    else:
        print(f"    {fname}: {len(cps.split(','))} icons OK")

# The text faces must keep their variable weight axis; the page asks for
# several weights and a static subset would silently synthesise them.
for fname in ("antonio.woff2", "jetbrains-mono.woff2"):
    font = TTFont(f"{out_dir}/{fname}")
    if "fvar" not in font:
        failed = True
        print(f"error: {fname} lost its variable-font axes", file=sys.stderr)
    else:
        axes = ",".join(a.axisTag for a in font["fvar"].axes)
        print(f"    {fname}: variable axes OK ({axes})")

sys.exit(1 if failed else 0)
PY

echo "==> done"
ls -l "$OUT_DIR"
