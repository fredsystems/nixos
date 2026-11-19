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
# configparser accepts either delimiter, any key case and whitespace around
# both, so a Path it would have read must not be lost here.
PATH_LINE = re.compile(
    rb"^[ \t]*path[ \t]*[=:][ \t]*(.*?)[ \t]*$",
    re.MULTILINE | re.IGNORECASE,
)
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


def encode_path(raw):
    """Percent-encode the bytes of raw that are not valid UTF-8."""
    text = raw.decode("utf-8", errors="surrogateescape")
    return UNDECODABLE.sub(
        lambda m: "%%%02X" % (ord(m.group()) - 0xDC00), text
    )


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
        content = f.read()
    mtime = os.stat(path).st_mtime
    stamp = datetime.datetime.fromtimestamp(mtime).strftime(DATE_FORMATS[0])
    date_line = "DeletionDate=" + stamp

    match = PATH_LINE.search(content)
    kept = "no Path line to keep"
    if match:
        path_line = "Path=" + encode_path(match.group(1))
        write_info(path, ["[Trash Info]", path_line, date_line], mtime)
        kept = "Path kept"
    if not match or not autotrash_can_read(path):
        write_info(path, ["[Trash Info]", date_line], mtime)
        if match:
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
