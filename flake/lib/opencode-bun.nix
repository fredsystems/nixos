# Whether a Bun satisfies OpenCode's `packageManager` pin, with the caret
# semantics upstream's own build script enforces (packages/script/src/index.ts
# checks `^<packageManager version>`). Shared by opencode-overlay.nix (the
# evaluation-time guard) and scripts/opencode-node-modules-hash.sh relock (the
# lock repair), so the two can never disagree about what "compatible" means.
#
# packageManager is the raw package.json field (e.g. "bun@1.4.4"); callers read
# it so this file stays pure and testable (flake/dev/checks.nix).
{
  lib,
  packageManager,
  bun,
}:
let
  required = builtins.head (lib.splitString "+" (lib.removePrefix "bun@" packageManager));
  parts = map lib.toInt (lib.splitVersion required);
  major = builtins.elemAt parts 0;
  minor = builtins.elemAt parts 1;
  patch = builtins.elemAt parts 2;
  # ^X.Y.Z: below the next major; for 0.x, below the next minor; for 0.0.x,
  # below the next patch.
  below =
    if major > 0 then
      "${toString (major + 1)}.0.0"
    else if minor > 0 then
      "0.${toString (minor + 1)}.0"
    else
      "0.0.${toString (patch + 1)}";
  # npm semver (what upstream checks with) only lets a prerelease satisfy a
  # range when the range names a prerelease of the same X.Y.Z. Nix's
  # versionOlder alone would accept e.g. 2.0.0-pre.1 as below 2.0.0.
  core = v: builtins.head (lib.splitString "-" v);
  isPrerelease = v: lib.hasInfix "-" v;
  prereleaseAllowed =
    !(isPrerelease bun.version) || (isPrerelease required && core bun.version == core required);
in
assert lib.assertMsg (lib.hasPrefix "bun@" packageManager)
  "OpenCode's package.json packageManager is '${packageManager}', not bun@<version>";
{
  inherit required;
  range = "^${required}";
  inherit (bun) version;
  compatible =
    prereleaseAllowed && lib.versionAtLeast bun.version required && lib.versionOlder bun.version below;
}
