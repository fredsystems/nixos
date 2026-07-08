# Per-system package outputs.
#
# Arguments:
#   inputs           — flake inputs attrset
#   forAllSystems    — nixpkgs.lib.genAttrs supportedSystems
{
  inputs,
  forAllSystems,
  ...
}:
let
  inherit (inputs)
    nixpkgs
    walls-catppuccin
    walls-zhichaoh
    walls-cozypixels
    ;
in
{
  packages = forAllSystems (
    system:
    let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ (import ../../overlays) ];
      };
      inherit (pkgs) lib;

      # Pinned release tarball of procedurally-generated catppuccin
      # wallpapers from daylinmorgan/catppuccin-wallpapers.  See the
      # comment in flake.nix (walls-cozypixels block) for the rationale
      # for using a release tarball instead of a flake input.
      walls-daylin-tarball = pkgs.fetchurl {
        url = "https://github.com/daylinmorgan/catppuccin-wallpapers/releases/download/v2022.05.02/all.tar.gz";
        hash = "sha256-kMpqJhr1sR/xhifKCp0IwmmfQ6SqKsWMRW34Nn8n2y8=";
      };
    in
    # The aggregate wallpaper bundle is a Linux-desktop-only asset
    # (consumed by the wayle wallpaper engine).  Skip it on Darwin so the
    # 1.4 GB closure is never built or surfaced there.
    lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      # sbomnix with the nix_2_31 PATH pin overridden (see the
      # `sbomnix` overlay in overlays/default.nix and
      # FIXME(nixpkgs-sbomnix-nix231-pin)).  cve-scan.yaml builds and
      # invokes THIS package (`.#sbomnix`) rather than `nixpkgs#sbomnix`
      # so the weekly CVE scan gets the fixed wrapper; a raw
      # `nixpkgs#sbomnix` would bypass our overlay and re-break.
      inherit (pkgs) sbomnix;

      # Aggregate catppuccin wallpaper collection.
      #
      # Layout under $out/share/backgrounds/:
      #   orangci/      - github:orangci/walls-catppuccin-mocha
      #   catppuccin/   - github:zhichaoh/catppuccin-wallpapers
      #                   (mirror of the original catppuccin/wallpapers,
      #                    11 categories preserved as subdirs)
      #   daylin/       - daylinmorgan/catppuccin-wallpapers v2022.05.02
      #                   release tarball (procedurally-generated PNGs
      #                   across the catppuccin palette)
      #   cozypixels/   - SleepyCatHey/CozyPixels Catppuccin/ subtree
      #                   (subdirs renamed to remove spaces & ampersands)
      #
      # The source-attributed subdir tree is the browsable, human-facing
      # layout.  In addition we materialise a FLAT directory at
      # $out/share/backgrounds-flat/ containing every image copied to the
      # top level with a collision-safe `<source>-<relpath>` name.  The
      # wayle wallpaper engine's cycler scans its cycling-directory
      # NON-recursively (fs::read_dir, not WalkDir), so pointing it at the
      # nested tree finds zero images; it must be pointed at the flat dir.
      catppuccin-wallpapers = pkgs.stdenvNoCC.mkDerivation {
        pname = "catppuccin-wallpapers";
        version = "2026-05-05";

        # Pass the four sources through the env so the install phase
        # can reference each one.
        srcs = [
          walls-catppuccin
          walls-zhichaoh
          walls-cozypixels
          walls-daylin-tarball
        ];

        # We have multiple unrelated sources; skip the default
        # unpackPhase and lay them out manually.
        dontUnpack = true;

        nativeBuildInputs = [ pkgs.gzip ];

        installPhase = ''
          runHook preInstall

          out_bg="$out/share/backgrounds"
          mkdir -p "$out_bg"

          ##################################################################
          # 1. orangci/walls-catppuccin-mocha
          #    Flat collection of images at the repo root.
          ##################################################################
          mkdir -p "$out_bg/orangci"
          cp -r ${walls-catppuccin}/. "$out_bg/orangci/"

          ##################################################################
          # 2. zhichaoh/catppuccin-wallpapers
          #    Preserve the 11 category subdirs.  Drop repo metadata
          #    files so only image content lands in the output.
          ##################################################################
          mkdir -p "$out_bg/catppuccin"
          cp -r ${walls-zhichaoh}/. "$out_bg/catppuccin/"
          rm -f \
            "$out_bg/catppuccin/.editorconfig" \
            "$out_bg/catppuccin/LICENSE" \
            "$out_bg/catppuccin/README.md"

          ##################################################################
          # 3. SleepyCatHey/CozyPixels — Catppuccin/ subtree only.
          #    The upstream subdirs use spaces and ampersands (e.g.
          #    "Anime & Gaming") which are awkward in shell paths.
          #    Rename to lowercase-with-hyphens during install.
          ##################################################################
          mkdir -p "$out_bg/cozypixels"
          cp -r "${walls-cozypixels}/Catppuccin/." "$out_bg/cozypixels/"
          # Files copied from another store path are read-only; make
          # them writable so subsequent rename/delete steps succeed.
          chmod -R u+w "$out_bg/cozypixels"
          # Normalise subdir names: lowercase, spaces -> '-', drop '&'.
          while IFS= read -r -d "" dir; do
            base="$(basename "$dir")"
            parent="$(dirname "$dir")"
            new="$(printf '%s' "$base" \
              | tr '[:upper:] ' '[:lower:]-' \
              | tr -d '&' \
              | tr -s '-')"
            new="''${new%-}"
            if [ "$base" != "$new" ]; then
              mv "$dir" "$parent/$new"
            fi
          done < <(find "$out_bg/cozypixels" -mindepth 1 -maxdepth 1 -type d -print0)
          # Normalise file extensions: upstream contains DOS-truncated
          # ".WEB" files (real WebP images) which an extension-based image
          # filter would skip.  Rename to lowercase ".webp".
          find "$out_bg/cozypixels" -type f -name '*.WEB' -print0 \
            | while IFS= read -r -d "" f; do
                mv "$f" "''${f%.WEB}.webp"
              done
          # Drop any non-image stragglers (e.g. Dolphin ".comments"
          # metadata, hidden dotfiles) that may slip in from upstream.
          find "$out_bg/cozypixels" -type f \
            ! -iname '*.png' \
            ! -iname '*.jpg' \
            ! -iname '*.jpeg' \
            ! -iname '*.webp' \
            ! -iname '*.gif' \
            -delete

          ##################################################################
          # 4. daylinmorgan/catppuccin-wallpapers release tarball.
          #    Tarball top-level layout: pngs/{caffeine,cat,lines,tux}/...
          #    Some files are stored as <name>.png.gz; gunzip them.
          ##################################################################
          mkdir -p "$out_bg/daylin"
          tar -xzf ${walls-daylin-tarball} -C "$out_bg/daylin" --strip-components=1
          # Decompress any .png.gz files in place.
          find "$out_bg/daylin" -type f -name '*.png.gz' -print0 \
            | while IFS= read -r -d "" f; do
                gunzip -f "$f"
              done

          ##################################################################
          # 5. Flat mirror for the wayle wallpaper cycler.
          #    wayle scans its cycling-directory non-recursively, so it
          #    cannot see images nested under the source-attributed subdirs
          #    above.  Copy every image into one flat directory with a
          #    collision-safe name derived from its path relative to
          #    backgrounds/ (slashes -> hyphens).  e.g.
          #      catppuccin/waves/foo.png -> catppuccin-waves-foo.png
          ##################################################################
          out_flat="$out/share/backgrounds-flat"
          mkdir -p "$out_flat"
          find "$out_bg" -type f \
            \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \
               -o -iname '*.webp' -o -iname '*.gif' \) -print0 \
            | while IFS= read -r -d "" img; do
                rel="''${img#"$out_bg"/}"
                flat="''${rel//\//-}"
                cp "$img" "$out_flat/$flat"
              done

          runHook postInstall
        '';

        meta = with pkgs.lib; {
          description = "Aggregated catppuccin wallpaper collection (orangci, zhichaoh, daylinmorgan, CozyPixels)";
          license = licenses.mit;
          platforms = platforms.linux;
        };
      };
    }
  );
}
