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

  # Pin opencode to the latest upstream release rather than nixpkgs'
  # (frequently stale) pin. See overlays/opencode.nix for the bump
  # procedure.
  opencode = final.callPackage ./opencode.nix { inherit (prev) opencode; };

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

  # `direnv`'s checkPhase runs `make test-go test-bash test-fish test-zsh`.
  # On darwin, the fish test suite hangs indefinitely (CI hits the 6h max
  # execution time with no output).  Tracked upstream:
  # https://github.com/NixOS/nixpkgs/issues/507531 (still open).  The related
  # zsh sigsuspend issue (#513543) is fixed in our pinned nixpkgs, but the
  # fish hang appears to be a separate codesign/sigsuspend interaction
  # (see also #208951).  Disable the check phase on darwin only; Linux still
  # runs the full test suite.
  direnv =
    if prev.stdenv.isDarwin then
      prev.direnv.overrideAttrs (_: {
        doCheck = false;
      })
    else
      prev.direnv;

  # FIXME(nixpkgs-sbomnix-nix231-pin): WORKAROUND, not a fix.
  #
  # nixpkgs' sbomnix package wrapper hard-prepends `nixVersions.nix_2_31`
  # to sbomnix's PATH (pkgs/by-name/sb/sbomnix/package.nix, with a stale
  # `# TODO: remove once sbomnix support new JSON format` referencing
  # https://github.com/tiiuae/sbomnix/issues/267).  That pin is now
  # self-defeating: Nix 2.31 emits the LEGACY `nix derivation show` JSON
  # (top-level `inputDrvs`/`inputSrcs`), but sbomnix 1.8.0 already parses
  # the NEW format (`inputs.drvs`/`inputs.srcs`, schema `version` 4) AND
  # explicitly rejects the legacy fields:
  #
  #   CRITICAL Unexpected JSON from `nix derivation show`: unsupported
  #   legacy `inputDrvs` ... refusing to continue.
  #
  # So every sbomnix invocation aborts, which broke the entire weekly
  # cve-scan.yaml (all hosts red).  sbomnix issue #267 is CLOSED (the
  # parser was updated in 1.8.0); the remaining bug is purely the stale
  # nixpkgs wrapper pin.  Re-point the wrapper's PATH at a Nix that emits
  # the modern format (Nix >= 2.34 in our pin emits schema version 4).
  #
  # Revert: once nixpkgs' sbomnix wrapper stops pinning nix_2_31 (drops
  # it or bumps it to a version emitting the new format), delete this
  # overlay and its FIXME.  See
  # .github/workflows/track-upstream-fixes.yaml.
  #
  # Only meaningful on Linux (cve-scan runs on the self-hosted Linux
  # runners); guarded so it is a no-op on darwin.
  sbomnix =
    if prev.stdenv.isDarwin then
      prev.sbomnix
    else
      prev.sbomnix.overrideAttrs (_: {
        makeWrapperArgs = [
          "--prefix PATH : ${
            prev.lib.makeBinPath [
              final.git
              final.nixVersions.nix_2_34
              final.python3.pkgs.graphviz
              final.nix-visualize
              final.vulnix
              final.grype
            ]
          }"
        ];
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
