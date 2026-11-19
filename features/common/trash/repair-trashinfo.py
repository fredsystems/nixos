"""Make a trash directory safe for autotrash to process.

autotrash aborts its whole run, deleting nothing, when it meets a single
.trashinfo file it cannot parse (most often one with no DeletionDate,
which some tools write). It also fails outright when the trash has no
info/ directory, which is the normal state on a host where nothing has
ever been trashed.

This runs before autotrash and fixes both:

  * info/ and files/ are created if missing (an empty trash is valid).
  * A .trashinfo autotrash cannot parse is rewritten with a DeletionDate
    taken from the .trashinfo file's own modification time, which is when
    the item was trashed. Its Path is kept so the item can still be
    restored; bytes that are not valid UTF-8 are percent-encoded, which is
    how the trash spec escapes Path anyway. The item then ages out under
    the normal --days rule.

The parse check mirrors autotrash's own (configparser, then the two
DeletionDate formats it accepts), so "repaired" means exactly "autotrash
would have aborted on this file". Every rewrite is checked the same way;
if the kept Path still makes it unreadable, the Path is dropped, because
an entry that blocks every purge is worse than one that cannot be
restored to its original location.

Usage: autotrash-repair [TRASH_DIR]
Default TRASH_DIR is $XDG_DATA_HOME/Trash (~/.local/share/Trash).
"""

import configparser
import datetime
import os
import re
import sys
import tempfile

DATE_FORMATS = ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M:%S.%fZ")
SECTION = "Trash Info"
# Fallback for files configparser rejects. It accepts either delimiter, any
# key case and whitespace around both, so a Path it would have read must not
# be lost here.
PATH_LINE = re.compile(
    r"^[ \t]*path[ \t]*[=:][ \t]*(.*?)[ \t]*$", re.MULTILINE | re.IGNORECASE
)
HEADER = re.compile(r"^[ \t]*\[(.*)\][ \t]*$", re.MULTILINE)
UNDECODABLE = re.compile("[\udc80-\udcff]")


def default_trash_dir():
    data_home = os.environ.get("XDG_DATA_HOME") or os.path.expanduser(
        "~/.local/share"
    )
    return os.path.join(data_home, "Trash")


def autotrash_can_read(path):
    try:
        parser = configparser.ConfigParser()
        if path not in parser.read(path):
            return False
        value = parser.get("Trash Info", "DeletionDate")
    except (configparser.Error, UnicodeDecodeError, OSError):
        return False
    for fmt in DATE_FORMATS:
        try:
            datetime.datetime.strptime(value, fmt)
            return True
        except ValueError:
            pass
    return False


def encode_path(value):
    """Percent-encode the bytes of value that were not valid UTF-8.

    value was decoded with surrogateescape, so each such byte is a lone
    surrogate here.
    """
    return UNDECODABLE.sub(
        lambda m: "%%%02X" % (ord(m.group()) - 0xDC00), value
    )


def find_path(text):
    """The Path of the [Trash Info] section, or None.

    Parsed properly when the file parses (most broken entries only lack a
    DeletionDate). Interpolation stays off: Path is percent-escaped, and
    "%20" is an interpolation error. Otherwise only the lines of the
    [Trash Info] section are searched, or those before any header when it
    has none, so a Path from another section is never picked up.
    """
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    try:
        parser.read_string(text)
        if parser.has_option(SECTION, "Path"):
            return parser.get(SECTION, "Path", raw=True)
    except configparser.Error:
        pass

    headers = list(HEADER.finditer(text))
    if not headers:
        scope = text
    else:
        scope = text[: headers[0].start()]
        for i, header in enumerate(headers):
            if header.group(1) == SECTION:
                end = headers[i + 1].start() if i + 1 < len(headers) else None
                scope = text[header.end():end]
                break
    match = PATH_LINE.search(scope)
    return match.group(1) if match else None


def write_info(path, lines, mtime):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".repair-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise
    os.utime(path, (mtime, mtime))


def repair(path):
    with open(path, "rb") as f:
        text = f.read().decode("utf-8", errors="surrogateescape")
    mtime = os.stat(path).st_mtime
    stamp = datetime.datetime.fromtimestamp(mtime).strftime(DATE_FORMATS[0])
    date_line = "DeletionDate=" + stamp

    value = find_path(text)
    kept = "no Path line to keep"
    if value is not None:
        path_line = "Path=" + encode_path(value)
        write_info(path, ["[Trash Info]", path_line, date_line], mtime)
        kept = "Path kept"
    if value is None or not autotrash_can_read(path):
        write_info(path, ["[Trash Info]", date_line], mtime)
        if value is not None:
            kept = "Path dropped, still unreadable with it"

    print(
        "repaired %s: %s (from file timestamp; %s)"
        % (os.path.basename(path), date_line, kept)
    )


def main(argv):
    if len(argv) > 2 or (len(argv) == 2 and argv[1].startswith("-")):
        print("usage: autotrash-repair [TRASH_DIR]", file=sys.stderr)
        return 2
    trash = argv[1] if len(argv) == 2 else default_trash_dir()
    info = os.path.join(trash, "info")

    for sub in (info, os.path.join(trash, "files")):
        os.makedirs(sub, mode=0o700, exist_ok=True)

    repaired = 0
    for name in sorted(os.listdir(info)):
        path = os.path.join(info, name)
        if not name.endswith(".trashinfo") or not os.path.isfile(path):
            continue
        try:
            if not autotrash_can_read(path):
                repair(path)
                repaired += 1
        except FileNotFoundError:
            # Restored or emptied by a file manager while we ran.
            continue

    if repaired:
        print("repaired %d trashinfo file(s) in %s" % (repaired, info))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
