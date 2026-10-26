"""Repair the damage FontForge does to Apple fonts patched by nerd-font-patcher.

FontForge 20251009, which nerd-font-patcher drives, breaks two things when
it writes a patched SF / New York face:

1. Names. Apple ships only Windows-platform name records, and its license
   text (ID 13) alone is about 60 KB. FontForge adds a Mac-platform copy of
   every record, which pushes the table's string storage past 64 KiB. The
   format's string offsets are 16 bits, so they wrap and every record
   stored after the license points at the wrong bytes. The typographic
   family and subfamily (IDs 16/17) come out as garbage, and fontconfig
   prefers ID 16 over ID 1, so every face other than Regular, Italic, Bold
   and Bold Italic lands in a nonsense family that no application can
   select by name. Stylistic-set names (IDs 256+) are garbled the same way.

2. Layout. Apple's kerning class tables are too large for FontForge's
   writer, which drops them; the patched faces kern by exactly zero.
   FontForge also ignores Apple's `trak` table (size-dependent tracking),
   which HarfBuzz applies when shaping the originals.

Usage: python3 apple-fonts-repair.py PATCHED_DIR

PATCHED_DIR holds exactly one patched font plus a `.source` file containing
the path of the original font it was made from.

`trak` does not reference glyphs and is copied back verbatim. Layout
(GDEF/GSUB/GPOS) is restored from Apple's original too. The patcher
replaces a handful of Apple glyphs with its own icons, so the original
tables are first pruned of those glyphs with the fontTools subsetter.
Apple's glyphs are then given back their original glyph IDs, with Nerd
glyphs filling the replaced slots and the rest appended, so the class
tables compile exactly as Apple's did. Compiling them against the patched
font's own glyph order fragments the classes, overflows the 16-bit
offsets, and fontTools' automatic subtable splitting then loses pairs.

Names: the Mac-platform records are dropped, as in Apple's originals. For
every remaining record the patcher does not own, the original's text is
copied back. IDs 16/17 are rebuilt from the patcher's own legacy family
(ID 1) and the original's typographic subfamily, which is what the patcher
meant to write.

Finally the repaired face is shaped against the original over a
multi-script sample; any difference in glyphs or positions fails the build.
Apple's variable fonts are the one exception: FontForge cannot write
variable fonts, so the patcher flattens them to a single static instance.
Apple applies optical-size tracking through feature variations, which only
take effect in a font that still has axes, so for those faces every advance
may differ by one constant amount. Glyphs and offsets must still match, and
any lost kerning pair would break the single constant.
"""

import pathlib
import sys

import uharfbuzz as hb
from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.ttLib.reorderGlyphs import reorderGlyphs

LAYOUT_TABLES = ("GDEF", "GSUB", "GPOS")
# Tables that do not reference glyphs, copied back verbatim.
VERBATIM_TABLES = ("trak",)

# Records nerd-font-patcher rewrites on purpose (see its FontnameParser).
PATCHER_OWNED = {1, 2, 3, 4, 5, 6, 16, 17}
STYLE_WORDS = {"italic", "oblique"}

SAMPLE = (
    "The quick brown fox jumps over the lazy dog. AVATAR Tyrol WAVE LT Yo "
    "'quoted' \u201cquotes\u201d \u2014 1/2 3/4 0123456789 fi fl ffi office "
    "\u00c0\u00c9\u00ce\u00d5\u00dc \u00e0\u00e9\u00ee\u00f5\u00fc \u00df "
    "\u0152 \u0153 \u00c6 \u00e6 \u00c5lborg "
    "\u0395\u03bb\u03bb\u03b7\u03bd\u03b9\u03ba\u03ac \u039a\u03b5\u03af\u03bc\u03b5\u03bd\u03bf "
    "\u041a\u0438\u0440\u0438\u043b\u043b\u0438\u0446\u0430 \u0410\u0412\u0422\u041e\u0420"
)
SAMPLE_FEATURES = (
    {},
    {"ss01": True, "ss02": True, "tnum": True, "frac": True, "case": True},
)


def restore_layout(original_path, patched):
    """Copy Apple's layout tables into the patched font without loss."""
    original = TTFont(original_path)
    original_order = original.getGlyphOrder()
    patched_order = patched.getGlyphOrder()
    patched_set = set(patched_order)
    original_set = set(original_order)

    nerd_glyphs = [g for g in patched_order if g not in original_set]
    fill = iter(nerd_glyphs)
    try:
        new_order = [g if g in patched_set else next(fill) for g in original_order]
    except StopIteration:
        sys.exit("patched font has fewer new glyphs than replaced ones")
    placed = set(new_order)
    new_order += [g for g in nerd_glyphs if g not in placed]

    for tag in LAYOUT_TABLES:
        if tag in patched:
            del patched[tag]
    reorderGlyphs(patched, new_order)

    options = subset.Options()
    options.layout_features = ["*"]
    options.layout_scripts = ["*"]
    options.layout_closure = False
    options.glyph_names = True
    options.notdef_outline = True
    options.name_IDs = ["*"]
    options.name_languages = ["*"]
    options.drop_tables = []
    options.prune_unicode_ranges = False
    subsetter = subset.Subsetter(options)
    subsetter.populate(glyphs=[g for g in original_order if g in patched_set])
    subsetter.subset(original)

    for tag in LAYOUT_TABLES:
        if tag in original:
            patched[tag] = original[tag]

    # The subsetter drops tables it does not understand, `trak` included,
    # so take those from a fresh copy of the original.
    pristine = TTFont(original_path)
    for tag in VERBATIM_TABLES:
        if tag in pristine:
            patched[tag] = pristine[tag]


def lookup(font, name_id):
    name = font["name"]
    record = name.getName(name_id, 3, 1, 0x409) or name.getName(name_id, 1, 0, 0)
    return record.toUnicode() if record is not None else None


def typographic_names(original, patched):
    """Return (family, subfamily) the patcher intended for IDs 16/17."""
    subfamily = (lookup(original, 17) or lookup(original, 2) or "Regular").split()
    weight = [w for w in subfamily if w.lower() not in STYLE_WORDS | {"regular"}]
    styles = [w for w in subfamily if w.lower() in STYLE_WORDS]

    # For non-RIBBI faces the patcher's ID 1 is "<family> <weight>", with its
    # own spelling of the weight (e.g. "SemiBold" for Apple's "Semibold").
    family = lookup(patched, 1).split()
    n = len(weight)
    if n and "".join(family[-n:]).lower() == "".join(weight).lower():
        weight = family[-n:]
        family = family[:-n]

    return " ".join(family), " ".join(weight + styles) or "Regular"


def repair_names(original_path, patched):
    original = TTFont(original_path)
    name = patched["name"]
    name.names = [r for r in name.names if r.platformID != 1]

    originals = {
        (r.nameID, r.platformID, r.platEncID, r.langID): r.toUnicode()
        for r in original["name"].names
    }
    for record in name.names:
        if record.nameID in PATCHER_OWNED:
            continue
        key = (record.nameID, record.platformID, record.platEncID, record.langID)
        if key in originals:
            record.string = originals[key]

    family, subfamily = typographic_names(original, patched)
    platforms = {(r.platformID, r.platEncID, r.langID) for r in name.names if r.nameID == 1}
    name.removeNames(nameID=16)
    name.removeNames(nameID=17)
    for platform in sorted(platforms):
        name.setName(family, 16, *platform)
        name.setName(subfamily, 17, *platform)
    return family, subfamily


def shape(path, features):
    font = hb.Font(hb.Face(hb.Blob.from_file_path(str(path))))
    buffer = hb.Buffer()
    buffer.add_str(SAMPLE)
    buffer.guess_segment_properties()
    hb.shape(font, buffer, features)
    return [
        (font.glyph_to_string(info.codepoint), pos.x_advance, pos.x_offset, pos.y_offset)
        for info, pos in zip(buffer.glyph_infos, buffer.glyph_positions)
    ]


def matches(expected, actual, flattened):
    if not flattened:
        return expected == actual
    if len(expected) != len(actual):
        return False
    if any(e[0] != a[0] or e[2:] != a[2:] for e, a in zip(expected, actual)):
        return False
    return len({e[1] - a[1] for e, a in zip(expected, actual)}) <= 1


def verify(original_path, repaired_path):
    flattened = "fvar" in TTFont(original_path, lazy=True)
    for features in SAMPLE_FEATURES:
        expected = shape(original_path, features)
        actual = shape(repaired_path, features)
        if not matches(expected, actual, flattened):
            diffs = [(i, e, a) for i, (e, a) in enumerate(zip(expected, actual)) if e != a]
            sys.exit(
                f"{repaired_path.name}: shaping differs from {original_path.name} "
                f"with features {sorted(features)}: {diffs[:5]}"
            )


def repair(patched_dir):
    source = pathlib.Path((patched_dir / ".source").read_text().strip())
    fonts = [p for p in patched_dir.iterdir() if p.suffix in (".otf", ".ttf")]
    if len(fonts) != 1:
        sys.exit(f"{patched_dir}: expected one patched font, found {len(fonts)}")
    target = fonts[0]

    patched = TTFont(target)
    restore_layout(source, patched)
    family, subfamily = repair_names(source, patched)

    # Name the file after the repaired family and style. The patcher's own
    # file name is not unique: SF Compact's roman and italic variable fonts
    # both come out as SFNerdFont-Compact.ttf, so one overwrote the other.
    renamed = target.with_name(f"{family.replace(' ', '')}-{subfamily.replace(' ', '')}{target.suffix}")
    patched.save(renamed)
    if renamed != target:
        target.unlink()
    verify(source, renamed)
    print(f"{renamed.name}: {family!r} / {subfamily!r}, layout verified")


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        repair(pathlib.Path(arg))
