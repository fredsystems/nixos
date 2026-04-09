# Nixpkgs overlays applied to all systems.
#
# This file is a standard nixpkgs overlay (final: prev: { ... }) and is
# imported directly by flake/lib/mk-system.nix and
# flake/lib/mk-darwin-system.nix via nixpkgs.overlays.
#
# To add overlays, create a new file next to this one and add it here as
# a callPackage entry, e.g.:
#
#   my-package = final.callPackage ./my-package.nix { };
#
# Each standalone overlay file should follow the callPackage convention:
#
#   { someDep, anotherDep, ... }:
#   derivation ...

final: prev: {
  cider3 = final.callPackage ./cider.nix { };

  # github-runner ≥ 2.333.1 has __noChroot = true set on its derivation
  # (nixpkgs commit 40231286, added as a darwin sandbox workaround).  On any
  # system with sandbox = true (the NixOS default), Nix refuses to even
  # schedule the build.  The flag is not needed for Linux builds, so strip it.
  github-runner = prev.github-runner.overrideAttrs (_: {
    __noChroot = false;
  });

  # Shadow the deprecated top-level `pkgs.hostPlatform` warnAlias (added
  # 2025-10-28 in nixpkgs aliases.nix) with the real value so that packages
  # which still reference `pkgs.hostPlatform` (e.g. the Flutter build
  # infrastructure used by yubioath-flutter) don't fire
  # "'hostPlatform' has been renamed to/replaced by 'stdenv.hostPlatform'"
  # evaluation warnings.  CI treats warnings as errors so this is
  # build-critical.  Mirrors the `withShadowedSystem` pattern in
  # flake/deployment/colmena.nix for the analogous `pkgs.system` alias.
  inherit (final.stdenv) hostPlatform;
}
