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

  # SyncClipboard desktop client. Upstream ships an AppImage only and it is
  # not in nixpkgs; see overlays/syncclipboard.nix for the ICU caveat.
  syncclipboard = final.callPackage ./syncclipboard.nix { };

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

  # FIXME(nixpkgs-575801-gearlever-structured-attrs): WORKAROUND, not a fix.
  #
  # buildPythonApplication now builds with __structuredAttrs, so each
  # makeWrapperArgs element reaches makeWrapper as ONE argument and is no
  # longer shell-expanded. gearlever 3.4.7 passes the literal string
  # "${gappsWrapperArgs[@]}" (meant to expand to the GTK wrapper args) and a
  # single "--prefix PATH : <bins>" string, so the build dies in fixupPhase
  # ("makeCWrapper: Unknown argument"). Upstream fix is the treewide
  # https://github.com/NixOS/nixpkgs/pull/575801 (not yet merged), which we
  # mirror: append the GTK args from preFixup, where the array exists, and
  # split the PATH prefix into separate elements.
  #
  # Gated on structured attrs plus the exact broken shape, so it is a no-op
  # before the switch and once the fix lands, and never drops args upstream
  # adds later.
  #
  # Revert: once our nixpkgs pin contains the fix, delete this override and
  # FIXME. See .github/workflows/track-upstream-fixes.yaml.
  gearlever =
    let
      inherit (prev) lib;
      gappsArg = "\${gappsWrapperArgs[@]}";
      pathPrefix = "--prefix PATH : ";
      args = prev.gearlever.makeWrapperArgs or [ ];
    in
    if
      (prev.gearlever.__structuredAttrs or false)
      && builtins.length args == 2
      && builtins.elemAt args 0 == gappsArg
      && lib.hasPrefix pathPrefix (builtins.elemAt args 1)
    then
      prev.gearlever.overridePythonAttrs (old: {
        preFixup = (old.preFixup or "") + ''
          makeWrapperArgs+=("''${gappsWrapperArgs[@]}")
        '';
        makeWrapperArgs = [
          "--prefix"
          "PATH"
          ":"
          (lib.removePrefix pathPrefix (builtins.elemAt args 1))
        ];
      })
    else
      prev.gearlever;

  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (
      _: pyprev:
      let
        inherit (prev) lib;

        # FIXME(nixpkgs-573108-typepy2-relax): WORKAROUND, not a fix.
        #
        # nixpkgs bumped typepy to 2.0.0, but sqliteschema and simplesqlite
        # still declare `typepy<2`, so pythonRuntimeDepsCheckHook fails
        # their builds. That transitively breaks sbomnix (via df-diskcache)
        # and with it the `.#sbomnix` dev-shell package and the CVE scan.
        # Fixed by https://github.com/NixOS/nixpkgs/pull/573108, which
        # landed on `staging` and has not reached the channel yet; this
        # adds the same pythonRelaxDeps entry.
        #
        # Gated on typepy >= 2 and the entry not being present already, so
        # it is a no-op before the bump and once the fix lands.
        #
        # Revert: once our nixpkgs pin contains the fix, delete
        # relaxTypepy, its two uses, and this FIXME. See
        # .github/workflows/track-upstream-fixes.yaml.
        relaxTypepy =
          pkg:
          let
            relaxed = pkg.pythonRelaxDeps or [ ];
          in
          if
            lib.versionAtLeast pyprev.typepy.version "2"
            && builtins.isList relaxed
            && !(builtins.elem "typepy" relaxed)
          then
            pkg.overridePythonAttrs (_: {
              pythonRelaxDeps = relaxed ++ [ "typepy" ];
            })
          else
            pkg;

        # FIXME(nixpkgs-573479-sphinxhook-structured-attrs): WORKAROUND, not a fix.
        #
        # Under __structuredAttrs `sphinxBuilders` is a bash array, but
        # sphinx-hook.sh still does `eval "__sphinxBuilders=($sphinxBuilders)"`,
        # and an unindexed array expands to its FIRST element only. reuse
        # asks for [ "html" "man" ], gets html alone, and fails because its
        # `man` output is never produced. reuse is a dependency of sbomnix
        # 1.9.0. Fixed in the hook by https://github.com/NixOS/nixpkgs/pull/573479
        # (plus #576194), both still on `staging`.
        #
        # Building reuse without structured attrs is exactly how it built
        # before the switch, where the hook works. Patching the hook itself
        # would rebuild every sphinx-documented package. Gated on reuse
        # actually using structured attrs and on the hook still lacking the
        # fix (read from the nixpkgs source tree, a plain eval-time read,
        # not import-from-derivation), so it switches itself off.
        #
        # Revert: once our nixpkgs pin contains the fix, delete this
        # override and FIXME. See .github/workflows/track-upstream-fixes.yaml.
        sphinxHookFixed = lib.hasInfix "concatTo __sphinxBuilders" (
          builtins.readFile "${prev.path}/pkgs/development/interpreters/python/hooks/sphinx-hook.sh"
        );
      in
      {
        sqliteschema = relaxTypepy pyprev.sqliteschema;
        simplesqlite = relaxTypepy pyprev.simplesqlite;

        reuse =
          if (pyprev.reuse.__structuredAttrs or false) && !sphinxHookFixed then
            pyprev.reuse.overridePythonAttrs (_: {
              __structuredAttrs = false;
            })
          else
            pyprev.reuse;
      }
    )
  ];

  # FIXME(toybox-0.8.15-darwin-readahead): WORKAROUND, not a fix.
  #
  # toybox 0.8.15 switched `readahead` to posix_fadvise(POSIX_FADV_WILLNEED)
  # (landley/toybox@9bd9d7dad5), which macOS does not provide, so the
  # Darwin build fails in toys/other/readahead.c.  Fixed upstream in
  # https://github.com/landley/toybox/commit/6a0c0ef5ee by dropping
  # CONFIG_READAHEAD from scripts/macos_miniconfig (which nixpkgs'
  # `make macos_defconfig` reads), but that landed after the 0.8.15 tag.
  # We apply the same one-line change here.  `extraConfig` cannot do this:
  # nixpkgs prepends it, so the generated CONFIG_READAHEAD=y would win.
  #
  # Darwin-only so the Linux toybox derivation is untouched.
  #
  # Revert: once nixpkgs ships toybox >= 0.8.16, delete this override and
  # FIXME.  See .github/workflows/track-upstream-fixes.yaml.
  toybox =
    if prev.stdenv.hostPlatform.isDarwin then
      prev.toybox.overrideAttrs (old: {
        # Leading newline: nixpkgs' postPatch ("patchShebangs .") has no
        # trailing newline, so plain concatenation would fuse the commands.
        postPatch = (old.postPatch or "") + ''

          sed -i '/^CONFIG_READAHEAD=y$/d' scripts/macos_miniconfig
        '';
      })
    else
      prev.toybox;

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
    let
      inherit (prev) lib;

      # FIXME(nixpkgs-575801-sbomnix-structured-attrs): WORKAROUND, not a fix.
      #
      # Same structured-attrs breakage as gearlever above: sbomnix passes
      # "--prefix PATH : <bins>" as ONE makeWrapperArgs element, which
      # makeWrapper rejects ("doesn't understand the arg"). Also fixed by
      # the not-yet-merged https://github.com/NixOS/nixpkgs/pull/575801;
      # this applies the same split. Gated on structured attrs plus the
      # exact broken shape, so it is a no-op before the switch and once the
      # fix lands.
      #
      # Revert: once our nixpkgs pin contains the fix, delete `wrapperFixed`
      # and this FIXME and use prev.sbomnix directly. See
      # .github/workflows/track-upstream-fixes.yaml.
      pathPrefix = "--prefix PATH : ";
      args = prev.sbomnix.makeWrapperArgs or [ ];
      wrapperFixed =
        if
          (prev.sbomnix.__structuredAttrs or false)
          && builtins.length args == 1
          && lib.hasPrefix pathPrefix (builtins.head args)
        then
          prev.sbomnix.overridePythonAttrs (_: {
            makeWrapperArgs = [
              "--prefix"
              "PATH"
              ":"
              (lib.removePrefix pathPrefix (builtins.head args))
            ];
          })
        else
          prev.sbomnix;
    in
    if prev.stdenv.hostPlatform.isDarwin || prev.sbomnix.version != final.sbomnixPatchedVersion then
      wrapperFixed
    else
      wrapperFixed.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ./sbomnix-recover-substituted-derivers.patch
          ./sbomnix-recover-pinned-version-cpes.patch
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
