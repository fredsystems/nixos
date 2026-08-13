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
  # Apple's SF / New York families, vendored rather than pulled from the
  # apple-fonts flake input. See overlays/apple-fonts.nix for why (short
  # version: Apple mutates the dmg URLs in place, which breaks *evaluation*
  # when they are flake inputs but is harmless for a fetchurl FOD).
  apple-fonts = final.callPackage ./apple-fonts.nix { };

  # Raise attic's hardcoded 500-chunk-per-GC-pass SQLite limit. See
  # overlays/attic-server.nix for the full rationale and the revert
  # condition (FIXME id: attic-gc-sqlite-chunk-limit).
  attic-server = final.callPackage ./attic-server.nix {
    inherit (prev) attic-server;
  };

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
    prev.lib.optionalAttrs (!prev.stdenv.hostPlatform.isDarwin) {
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
    if prev.stdenv.hostPlatform.isDarwin then
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
  # it or bumps it to a version emitting the new format), delete the
  # makeWrapperArgs override and this FIXME.  See
  # .github/workflows/track-upstream-fixes.yaml.
  #
  # FIXME(sbomnix-substituted-deriver-drop): WORKAROUND, not a fix.
  #
  # sbomnix drops every runtime-closure path whose deriver `nix path-info`
  # reports as unknown.  That is every substituter-fetched path, because the
  # deriver pointer is only recorded for locally-built outputs.  On our
  # runners the result was an SBOM covering 418 of 3242 paths (13%), missing
  # openssl, bash and glibc while keeping unit-*.service and etc-* glue --
  # i.e. it silently scanned almost nothing and reported success.  Coverage
  # tracked cache warmth, so the CVE count swung per-runner and per-week, and
  # occasionally hit zero matches, which then tripped cve-scan.yaml's
  # "grype output has no .vulnerabilities key" guard and turned hosts red.
  #
  # The patch reconstructs output -> deriver by inverting `outputs.<name>.path`
  # over the local .drv graph, which does not depend on the store's deriver
  # pointers.  Restores 98.9% coverage (408 -> 2835 components) in ~2s.
  #
  # Revert: once sbomnix recovers derivers itself (no upstream issue filed
  # yet), delete the `patches` attribute, the patch file, and this FIXME.
  # See .github/workflows/track-upstream-fixes.yaml.
  #
  # FIXME(sbomnix-pinned-version-cpe-drop): WORKAROUND, not a fix.
  #
  # sbomnix attaches nixpkgs metadata only when a component's output or
  # derivation path is byte-identical to the one the nixpkgs attribute
  # evaluates to.  When a closure pins a different version than the attr
  # currently builds, nothing matches and the component is emitted with
  # no CPE -- which makes it invisible to grype and reads as "no known
  # vulnerabilities" rather than "never checked".
  #
  # This was hiding most of the fleet.  Servers pinning linux 6.18.41
  # while `pkgs.linux` was 6.18.43 emitted the kernel with `cpe: null`
  # and scored ZERO kernel CVEs, while Daytona (whose kernel matched its
  # attr) scored 74.  A newer kernel looking cleaner than an older one is
  # the signature of this bug, not a security finding.
  #
  # The patch adds a lowest-priority pname fallback that carries over
  # only the CPE, retargeted to the version actually in the closure.
  # Takes a server closure from 59 to 97 scannable components.
  #
  # Revert: once sbomnix matches metadata for pinned versions itself (no
  # upstream issue filed yet), delete the patch and this FIXME.  See
  # .github/workflows/track-upstream-fixes.yaml.
  #
  # All three workarounds above are only meaningful on Linux (cve-scan
  # runs on the self-hosted Linux runners); guarded to no-op on darwin.
  #
  # The two source patches are additionally version-gated to exactly
  # 1.8.0, the version they were written against.  Two reasons:
  #
  #   * `nixpkgs-stable` currently ships 1.7.6, whose tree predates
  #     builder.py/runtime.py/package_meta.py entirely.  Applying the
  #     patches there fails the build ("4 out of 4 hunks ignored").
  #     Nothing consumes the stable sbomnix today, so this is latent
  #     rather than broken -- but it would break the moment something
  #     did.
  #   * A patch that silently stops applying is worse than one that
  #     fails: the scan would keep running and quietly go back to
  #     reporting 3% of each closure as clean.
  #
  # An exact-version gate means a bump to 1.8.1 drops the patches, the
  # scannable-component assertion in cve-scan.yaml trips, and the scan
  # fails loudly instead of under-reporting.  The `sbomnix-patch-version`
  # flake check (flake/dev/checks.nix) fires at eval time so the bump is
  # caught before it ever reaches a scan.  On a bump: re-verify both
  # patches against the new tree, then widen this bound.
  sbomnixPatchedVersion = "1.8.0";

  sbomnix =
    if prev.stdenv.hostPlatform.isDarwin || prev.sbomnix.version != final.sbomnixPatchedVersion then
      prev.sbomnix
    else
      prev.sbomnix.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ./sbomnix-recover-substituted-derivers.patch
          ./sbomnix-recover-pinned-version-cpes.patch
        ];
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

  # FIXME(nixpkgs-540439-dfdiskcache-pandas3): WORKAROUND, not a fix.
  #
  # nixpkgs bumped pandas to 3.0.4, which trips df-diskcache's pinned
  # `pandas<3,>=1` runtime dependency check.  Upstream still pins
  # `pandas<3` as of the v0.1.0 tag, but the package itself works fine
  # against pandas 3.x.  df-diskcache is a transitive runtime dep of
  # `sbomnix`, so the failed dependency check aborts the sbomnix build
  # (both `nixpkgs#sbomnix` and this repo's `.#sbomnix` override, since
  # the overlay only re-wraps sbomnix and does not rebuild dfdiskcache).
  #
  # The fix is a one-line `pythonRelaxDeps = [ "pandas" ];` on the
  # dfdiskcache package, mirroring NixOS/nixpkgs PR #540439.
  #
  # Revert: once #540439 (or an equivalent upstream fix) lands in our
  # pinned nixpkgs, delete this `pythonPackagesExtensions` block and
  # its FIXME.  See .github/workflows/track-upstream-fixes.yaml.
  pythonPackagesExtensions = prev.pythonPackagesExtensions or [ ] ++ [
    (_pyFinal: pyPrev: {
      dfdiskcache = pyPrev.dfdiskcache.overridePythonAttrs (old: {
        pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "pandas" ];
      });
    })
  ];

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
