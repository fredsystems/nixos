#!/usr/bin/env python3
"""Verify the flake-input CI category mapping agrees across all locations.

The mapping that decides which hosts CI rebuilds when a flake input
changes is hand-maintained in four places (see the
`nixos-input-category-sync` skill). They must agree, or CI either
over-builds (wastes runner time) or under-builds (ships an unverified
host, which is worse).

Historically this was enforced only by an agent remembering a skill.
It failed: `nixpkgs-kernel` was added with a `# CI: server` comment in
flake.nix but never added to either bash array, so every monthly kernel
bump rebuilt two desktops that no-op the pin. An audit caught it and the
finding then sat unfixed in a markdown file. This script exists so that
class of drift is caught by a machine instead.

Checked locations:

  1. flake.nix                       -- `# CI: <category>` comments
  2. .github/workflows/ci-linux.yaml -- `input_category` bash array
  3. .github/workflows/ci-darwin.yaml-- `input_category` bash array (darwin vocab)
  4. .opencode/.../impacted-hosts.sh -- `INPUT_CATEGORY` bash array

flake.lock's root inputs are the source of truth for *which* inputs
exist. Exit 0 if consistent, 1 otherwise with a report.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

LINUX_CATEGORIES = {"global", "desktop", "server", "desktop+fredhub", "skip"}
DARWIN_CATEGORIES = {"darwin", "skip"}

FLAKE_NIX = "flake.nix"
FLAKE_LOCK = "flake.lock"
CI_LINUX = ".github/workflows/ci-linux.yaml"
CI_DARWIN = ".github/workflows/ci-darwin.yaml"
IMPACTED = (
    ".opencode/skills/projects/nixos-eval-impacted-hosts/scripts/impacted-hosts.sh"
)


def repo_root() -> Path:
    here = Path(__file__).resolve()
    for parent in here.parents:
        if (parent / FLAKE_NIX).is_file() and (parent / FLAKE_LOCK).is_file():
            return parent
    sys.exit("ERROR: could not locate repo root (no flake.nix + flake.lock above me)")


def root_inputs(root: Path) -> set[str]:
    data = json.loads((root / FLAKE_LOCK).read_text())
    return set(data["nodes"]["root"]["inputs"].keys())


def normalize(category: str) -> str:
    """Comments are prose-ish; arrays are exact. Reduce to a common form."""
    category = category.split("(")[0].strip()
    return category.replace("desktop + fredhub", "desktop+fredhub").strip()


def parse_flake_nix(root: Path) -> dict[str, str]:
    """Map input -> category from `# CI:` comments preceding each declaration."""
    text = (root / FLAKE_NIX).read_text()

    start = text.index("inputs = {")
    end = text.index("\n  outputs") if "\n  outputs" in text else len(text)
    block = text[start:end]

    found: dict[str, str] = {}
    pending: str | None = None
    for line in block.splitlines():
        comment = re.match(r"\s*#\s*CI:\s*(.+?)\s*$", line)
        if comment:
            pending = comment.group(1)
            continue
        decl = re.match(r"\s{4}([A-Za-z][\w-]*)\s*=\s*\{", line)
        if decl:
            if pending is not None:
                found[decl.group(1)] = normalize(pending)
            pending = None
            continue
        # A non-blank, non-comment line breaks the comment/decl adjacency.
        if line.strip() and not line.strip().startswith("#"):
            pending = None
    return found


def parse_bash_array(root: Path, rel: str, name: str) -> dict[str, str]:
    text = (root / rel).read_text()
    try:
        start = text.index(name)
    except ValueError:
        sys.exit(f"ERROR: {rel} has no `{name}` array")
    end = text.index(")", start)
    body = text[start:end]
    return {k: normalize(v) for k, v in re.findall(r"\[([\w.-]+)\]=\"([^\"]+)\"", body)}


def main() -> int:
    root = repo_root()
    lock = root_inputs(root)

    fnix = parse_flake_nix(root)
    linux = parse_bash_array(root, CI_LINUX, "input_category=(")
    darwin = parse_bash_array(root, CI_DARWIN, "input_category=(")
    script = parse_bash_array(root, IMPACTED, "INPUT_CATEGORY=(")

    errors: list[str] = []

    # 1. Every locked root input must appear in every location.
    for source_name, mapping in (
        (FLAKE_NIX, fnix),
        (CI_LINUX, linux),
        (CI_DARWIN, darwin),
        (IMPACTED, script),
    ):
        for missing in sorted(lock - set(mapping)):
            errors.append(
                f"{source_name}: missing input {missing!r} "
                f"(falls through to the default category -- may over- or under-build)"
            )
        for extra in sorted(set(mapping) - lock):
            errors.append(
                f"{source_name}: input {extra!r} is not a root input in flake.lock "
                f"(stale entry, likely a removed input)"
            )

    # 2. The three Linux locations must agree exactly.
    for name in sorted(lock):
        vals = {
            FLAKE_NIX: fnix.get(name),
            CI_LINUX: linux.get(name),
            IMPACTED: script.get(name),
        }
        present = {k: v for k, v in vals.items() if v is not None}
        if len(set(present.values())) > 1:
            rendered = ", ".join(f"{k}={v!r}" for k, v in present.items())
            errors.append(f"{name}: Linux categories disagree -- {rendered}")

    # 3. Categories must come from the valid vocabulary.
    for source_name, mapping, allowed in (
        (FLAKE_NIX, fnix, LINUX_CATEGORIES),
        (CI_LINUX, linux, LINUX_CATEGORIES),
        (IMPACTED, script, LINUX_CATEGORIES),
        (CI_DARWIN, darwin, DARWIN_CATEGORIES),
    ):
        for name, category in sorted(mapping.items()):
            if category not in allowed:
                errors.append(
                    f"{source_name}: input {name!r} has category {category!r}, "
                    f"not one of {sorted(allowed)}"
                )

    if errors:
        print("flake-input category sync FAILED:\n", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        print(
            "\nSee the `nixos-input-category-sync` skill for the reference table.",
            file=sys.stderr,
        )
        return 1

    print(f"flake-input category sync OK ({len(lock)} inputs, 4 locations agree)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
