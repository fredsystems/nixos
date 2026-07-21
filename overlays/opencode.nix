# Track opencode's upstream release cadence instead of nixpkgs' lag.
#
# opencode ships multiple releases a week; nixpkgs' pin only moves when
# someone bumps pkgs/by-name/op/opencode/package.nix, which lags upstream
# by anywhere from days to weeks. This overlay repoints the existing
# nixpkgs derivation at the newest upstream tag, reusing its buildPhase
# / wrapper logic verbatim (see the upstream package.nix for why it's
# structured this way: a fixed-output `node_modules` derivation feeding a
# non-network build).
#
# Bumping this file:
#   1. Update `version` below.
#   2. Get the new source hash:
#        nix run nixpkgs#nix-prefetch-github -- anomalyco opencode --rev v<version>
#   3. Set `src.hash` to that value.
#   4. Set `node_modules.outputHash` to a wrong placeholder
#      (e.g. lib.fakeHash) and run:
#        nix build .#nixosConfigurations.<host>.pkgs.opencode.node_modules
#      to get the real hash from the mismatch error, then fill it in.
#   5. `nix build .#nixosConfigurations.<host>.pkgs.opencode` to confirm.
#
# Usage in overlays/default.nix:
#   opencode = final.callPackage ./opencode.nix { opencode = prev.opencode; };
{
  opencode,
  fetchFromGitHub,
}:
opencode.overrideAttrs (
  _finalAttrs: prevAttrs: rec {
    version = "1.18.4";

    src = fetchFromGitHub {
      owner = "anomalyco";
      repo = "opencode";
      tag = "v${version}";
      hash = "sha256-tGMO5JktINO8kXAHFQftn+JCrzwvpmNipTa8V0aIfNI=";
    };

    node_modules = prevAttrs.node_modules.overrideAttrs (_: {
      inherit version src;
      outputHash = "sha256-jMZSDlqNObSmWJZ0Xn0IwfYC2+mBbRYorfgD5Y2sHWs=";
    });
  }
)
