# Apple's San Francisco / New York font families, packaged from Apple's
# developer-download dmgs.
#
# Why this is vendored instead of using github:Lyndeno/apple-fonts.nix
# (dropped as a flake input on 2026-08-06):
#
# Upstream models each dmg as a `flake = false` flake *input*. Apple
# serves those dmgs from a single mutable CDN path -- no version in the
# URL, no history kept -- so any re-publish silently invalidates the
# narHash pinned in flake.lock. Flake inputs are materialised during
# *evaluation*, which makes that mismatch a hard eval error rather than
# a build error: on 2026-08-06 Apple re-uploaded SF-Pro.dmg 86 bytes
# larger and every desktop eval, plus the fleet-manifest job, failed
# until the input was bumped.
#
# `fetchurl` is a fixed-output derivation instead. Evaluation needs only
# the hash *string* and never the bytes; the bytes are fetched at build
# time and only on a cache miss, which does not happen because the
# patched font output lives in Attic. Apple can re-publish whenever it
# likes and nothing breaks -- we bump the hash when we choose. A stale
# hash here is not an outage.
#
# .github/workflows/update-apple-fonts.yaml watches the CDN ETags and
# opens the bump PR when a family actually changes.
#
# Bumping a hash by hand:
#   nix store prefetch-file --json --name SF-Pro.dmg \
#     https://devimages-cdn.apple.com/design/resources/download/SF-Pro.dmg
#
# Each family yields two attributes: the plain fonts (`sf-pro`) and the
# Nerd Fonts-patched variant (`sf-pro-nerd`). Both are lazy, so a family
# that nothing references is never fetched or built.
{
  lib,
  stdenvNoCC,
  fetchurl,
  p7zip,
  parallel,
  nerd-font-patcher,
}:
let
  baseUrl = "https://devimages-cdn.apple.com/design/resources/download";

  # `file`    -- basename on Apple's CDN.
  # `pkgName` -- the installer payload inside the dmg.
  # `hash`    -- flat sha256 of the dmg (see prefetch command above).
  families = {
    sf-pro = {
      file = "SF-Pro.dmg";
      pkgName = "SF Pro Fonts.pkg";
      hash = "sha256-qQlPDem3idc1RO5Q/FKgiE1Kn3/PYt5Sl04yBPOnSmI=";
      description = "Apple SF Pro, the San Francisco system typeface";
    };

    sf-compact = {
      file = "SF-Compact.dmg";
      pkgName = "SF Compact Fonts.pkg";
      hash = "sha256-LIkAOWe+WaaGeqXeEgZjUtmmtEt4XPK5/4jvDXf/KPw=";
      description = "Apple SF Compact, the narrow San Francisco variant";
    };

    sf-mono = {
      file = "SF-Mono.dmg";
      pkgName = "SF Mono Fonts.pkg";
      hash = "sha256-bUoLeOOqzQb5E/ZCzq0cfbSvNO1IhW1xcaLgtV2aeUU=";
      description = "Apple SF Mono, the monospaced San Francisco variant";
    };

    ny = {
      file = "NY.dmg";
      pkgName = "NY Fonts.pkg";
      hash = "sha256-HC7ttFJswPMm+Lfql49aQzdWR2osjFYHJTdgjtuI+PQ=";
      description = "Apple New York, the serif companion to San Francisco";
    };
  };

  mkFont =
    name: nerd:
    let
      family = families.${name};
    in
    stdenvNoCC.mkDerivation {
      name = if nerd then "${name}-nerd" else name;

      src = fetchurl {
        url = "${baseUrl}/${family.file}";
        inherit (family) hash;
      };

      nativeBuildInputs = [
        p7zip
      ]
      ++ lib.optionals nerd [
        parallel
        nerd-font-patcher
      ];

      # The dmg contains an installer .pkg, which in turn contains a cpio
      # archive named `Payload~`. Three unpacks to reach the font files.
      unpackPhase = ''
        runHook preUnpack
        7z x "$src"
        7z x './*/${family.pkgName}'
        7z x 'Payload~'
        runHook postUnpack
      '';

      setSourceRoot = "sourceRoot=$(pwd)";

      # nerd-font-patcher writes each patched face into the working
      # directory, leaving the originals in the unpacked subtree. That is
      # what lets installPhase below select patched faces with -maxdepth 1.
      buildPhase = lib.optionalString nerd ''
        runHook preBuild
        find \( -name \*.ttf -o -name \*.otf \) -print0 \
          | parallel --will-cite -j "$NIX_BUILD_CORES" -0 \
              nerd-font-patcher --no-progressbars -c {}
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p "$out/share/fonts/opentype" "$out/share/fonts/truetype"
      ''
      + (
        if nerd then
          ''
            find -maxdepth 1 -name \*.otf -exec mv {} "$out/share/fonts/opentype/" \;
            find -maxdepth 1 -name \*.ttf -exec mv {} "$out/share/fonts/truetype/" \;
          ''
        else
          ''
            find -name \*.otf -exec mv {} "$out/share/fonts/opentype/" \;
            find -name \*.ttf -exec mv {} "$out/share/fonts/truetype/" \;
          ''
      )
      + ''
        runHook postInstall
      '';

      meta = {
        inherit (family) description;
        homepage = "https://developer.apple.com/fonts/";
        # Apple's font licence permits use but not redistribution, so
        # these are unfree. features/desktop/fonts lists the names it
        # installs in nixpkgs.config.allowUnfreePredicate.
        license = lib.licenses.unfree;
        platforms = lib.platforms.all;
      };
    };
in
lib.listToAttrs (
  lib.concatMap (name: [
    (lib.nameValuePair name (mkFont name false))
    (lib.nameValuePair "${name}-nerd" (mkFont name true))
  ]) (lib.attrNames families)
)
