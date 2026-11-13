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

  # nixpkgs' updater broke when the MultiViewer API stopped returning
  # download ids, leaving it stuck at 2.8.4. Pinned in
  # overlays/multiviewer-for-f1.json and bumped daily by
  # update-multiviewer.yaml; defers to nixpkgs once it catches up.
  multiviewer-for-f1 = final.callPackage ./multiviewer-for-f1.nix {
    inherit (prev) multiviewer-for-f1;
  };

  # SyncClipboard desktop client. Upstream ships an AppImage only and it is
  # not in nixpkgs; see overlays/syncclipboard.nix for the ICU caveat.
  syncclipboard = final.callPackage ./syncclipboard.nix { };

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

  # FIXME(nixpkgs-585413-dwarfs-libarchive): WORKAROUND, not a fix.
  #
  # Since libarchive 3.8.10 (libarchive/libarchive#3354),
  # archive_write_close() returns ARCHIVE_FATAL for a writer that already
  # failed. dwarfsextract then throws before joining its I/O thread and
  # aborts via std::terminate(), failing the pwb/raw/xar
  # dwarfsextract_format_test cases, so dwarfs 0.15.8 does not build (and
  # Hydra has no cached copy). gearlever depends on dwarfs, which takes out
  # both desktops. Report: https://github.com/NixOS/nixpkgs/issues/585413.
  # We apply the same upstream patch (https://github.com/mhx/dwarfs/pull/391)
  # with the same hash as the nixpkgs fix,
  # https://github.com/NixOS/nixpkgs/pull/586760 (not yet merged).
  #
  # Gated on 0.15.8 without that patch, so it is a no-op once nixpkgs carries
  # the fix or dwarfs moves to a release that includes it.
  #
  # Revert: once our nixpkgs pin contains the fix, delete this override and
  # FIXME. See .github/workflows/track-upstream-fixes.yaml.
  dwarfs =
    let
      inherit (prev) lib;
      fixCommit = "0f5a7720f03dbb2e2fb12300272826fb458aac5f";
      alreadyPatched = lib.any (
        p: lib.isDerivation p && lib.any (lib.hasInfix fixCommit) (p.urls or [ ])
      ) (prev.dwarfs.patches or [ ]);
    in
    if prev.dwarfs.version == "0.15.8" && !alreadyPatched then
      prev.dwarfs.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          (prev.fetchpatch {
            url = "https://github.com/mhx/dwarfs/commit/${fixCommit}.patch?full_index=1";
            hash = "sha256-laGlfPZgfG5Xn8Se/7XTK3wYg0hhsOMQhzWTlwBZQR8=";
          })
        ];
      })
    else
      prev.dwarfs;

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

  # sbomnix source patches.  (The deriver-recovery patch that used to live
  # here, FIXME(sbomnix-substituted-deriver-drop), was retired at 1.9.0:
  # upstream now keeps substituted paths itself, and an unpatched 1.9.0
  # covers the same 88% of sdrhub's closure, component for component, as
  # one carrying the patch.  See its entry in
  # .github/tracked-upstream-fixes.json.)
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
  # Still needed on 1.9.0, whose new canonical-CPE mapping only covers
  # components it infers when metadata cannot be loaded at all: on sdrhub
  # it takes scannable components from 61 to 100, and restores CPEs for
  # glibc, openssl, bash, curl, xz, zlib, sqlite and the kernel.
  #
  # Revert: once sbomnix matches metadata for pinned versions itself (no
  # upstream issue filed yet), delete the patch and this FIXME.  See
  # .github/workflows/track-upstream-fixes.yaml.
  #
  # Only meaningful on Linux (cve-scan runs on the self-hosted Linux
  # runners); guarded to no-op on darwin.
  #
  # The patch is additionally version-gated to exactly 1.9.0, the version
  # it was last verified against.  Two reasons:
  #
  #   * `nixpkgs-stable` ships an older sbomnix whose tree predates the
  #     code the patch touches; applying it there fails the build.
  #     Nothing consumes the stable sbomnix today, so this is latent
  #     rather than broken -- but it would break the moment something
  #     did.
  #   * A patch that silently stops applying is worse than one that
  #     fails: the scan would keep running and quietly lose its CPEs.
  #
  # An exact-version gate means a bump drops the patch.  The
  # `sbomnix-patch-version` flake check (flake/dev/checks.nix) is meant to
  # catch that at eval time, and the scannable-component floor in
  # cve-scan.yaml at scan time.  On a bump: re-verify the patch against
  # the new tree, then move this bound.
  #
  # The bound was 1.8.0 until nixpkgs moved to 1.9.0, which silently
  # dropped both patches on main: the check above was not run by any
  # workflow, and the scan's floor (then 50) sat below the unpatched 61.
  # Re-verified at 1.9.0: the CPE patch applies with small offsets (each
  # hunk confirmed to land in the intended function), sbomnix's own test
  # suite passes with it, and an SBOM of sdrhub is identical with and
  # without the retired deriver patch.
  sbomnixPatchedVersion = "1.9.0";

  sbomnix =
    if prev.stdenv.hostPlatform.isDarwin || prev.sbomnix.version != final.sbomnixPatchedVersion then
      prev.sbomnix
    else
      prev.sbomnix.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
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
