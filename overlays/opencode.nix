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
#   4. Set `passthru.node_modules.outputHash` to a wrong placeholder
#      (e.g. lib.fakeHash) and run:
#        nix build .#nixosConfigurations.<host>.pkgs.opencode.node_modules
#      to get the real hash from the mismatch error, then fill it in.
#   5. `nix build .#nixosConfigurations.<host>.pkgs.opencode` to confirm.
#
# Note on where `node_modules` lives: upstream moved it from a top-level
# derivation attribute into `passthru`, and made it a function of the outer
# `finalAttrs` (`inherit (finalAttrs) version src`). Two consequences:
#   * It must be overridden through `passthru`, not at the top level. The old
#     top-level `node_modules` override evaluated to "attribute 'node_modules'
#     missing" once nixpkgs restructured the package.
#   * `version` and `src` no longer need re-inheriting into it -- setting them
#     on the outer derivation propagates automatically. Only `outputHash` has
#     to be restated, because the vendored dependency tree differs per release.
#
# Usage in overlays/default.nix:
#   opencode = final.callPackage ./opencode.nix { opencode = prev.opencode; };
{
  opencode,
  fetchFromGitHub,
}:
opencode.overrideAttrs (
  finalAttrs: prevAttrs: {
    version = "1.18.22";

    src = fetchFromGitHub {
      owner = "anomalyco";
      repo = "opencode";
      tag = "v${finalAttrs.version}";
      hash = "sha256-EvhjSETkOL4s4PlUB2zvALU4eD2iCHZ3AFh+3ro95dw=";
    };

    passthru = prevAttrs.passthru // {
      node_modules = prevAttrs.passthru.node_modules.overrideAttrs (_: {
        outputHash = "sha256-dJtPehOvtG5RuzXEhEIXhu15liVcCKTeFwRTElcox4w=";
      });
    };
  }
)
