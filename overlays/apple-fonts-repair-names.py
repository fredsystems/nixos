"""Repair the name tables of fonts produced by nerd-font-patcher.

Apple ships only Windows-platform name records, and its license text
(ID 13) alone is about 60 KB. FontForge, which nerd-font-patcher drives,
adds a Mac-platform copy of every record on output, which pushes the
table's string storage past 64 KiB. The format's string offsets are 16
bits, so they wrap and every record stored after the license points at
the wrong bytes. The typographic family and subfamily (IDs 16/17) come
out as garbage, and fontconfig prefers ID 16 over ID 1, so every face
other than Regular, Italic, Bold and Bold Italic lands in a nonsense
family that no application can select by name. Stylistic-set names
(IDs 256+) are garbled the same way.

Usage: python3 apple-fonts-repair-names.py PATCHED_DIR...

Each PATCHED_DIR holds exactly one patched font plus a `.source` file
containing the path of the original font it was made from.

The Mac-platform records are dropped, as in Apple's originals. For every
remaining record the patcher does not own, the original's text is copied
back. IDs 16/17 are rebuilt from the patcher's own legacy family (ID 1)
and the original's typographic subfamily, which is what the patcher
meant to write.
"""

import pathlib
import sys

from fontTools.ttLib import TTFont

# Records nerd-font-patcher rewrites on purpose (see its FontnameParser).
PATCHER_OWNED = {1, 2, 3, 4, 5, 6, 16, 17}
STYLE_WORDS = {"italic", "oblique"}


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


def repair(patched_dir):
    source = pathlib.Path((patched_dir / ".source").read_text().strip())
    fonts = [p for p in patched_dir.iterdir() if p.suffix in (".otf", ".ttf")]
    if len(fonts) != 1:
        sys.exit(f"{patched_dir}: expected one patched font, found {len(fonts)}")
    target = fonts[0]

    original = TTFont(source)
    patched = TTFont(target)
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

    patched.save(target)
    print(f"{target.name}: {family!r} / {subfamily!r}")


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        repair(pathlib.Path(arg))
