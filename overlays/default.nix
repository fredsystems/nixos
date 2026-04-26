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
  # On darwin, keep __noChroot = true (the upstream default) since the darwin
  # sandbox requires it.
  github-runner = prev.github-runner.overrideAttrs (
    _:
    prev.lib.optionalAttrs (!prev.stdenv.isDarwin) {
      __noChroot = false;
    }
  );

  # Workaround for the staging-next autoconf update that forces Clang to
  # `-std=gnu23`, breaking C code that isn't C23-compliant.  See upstream
  # tracking issue: https://github.com/NixOS/nixpkgs/issues/511329.
  # `dateutils` 0.4.11 fails to compile `dgrep.c` under C23 on aarch64-darwin
  # (Clang is the default C compiler on macOS, so this only affects darwin).
  # Pin CFLAGS back to the previous default of gnu17 via configureFlags.
  dateutils =
    if prev.stdenv.isDarwin then
      prev.dateutils.overrideAttrs (old: {
        configureFlags = (old.configureFlags or [ ]) ++ [ "CFLAGS=-std=gnu17" ];
      })
    else
      prev.dateutils;

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
