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
      pkgs = import nixpkgs { inherit system; };

      # Pinned release tarball of procedurally-generated catppuccin
      # wallpapers from daylinmorgan/catppuccin-wallpapers.  See the
      # comment in flake.nix (walls-cozypixels block) for the rationale
      # for using a release tarball instead of a flake input.
      walls-daylin-tarball = pkgs.fetchurl {
        url = "https://github.com/daylinmorgan/catppuccin-wallpapers/releases/download/v2022.05.02/all.tar.gz";
        hash = "sha256-kMpqJhr1sR/xhifKCp0IwmmfQ6SqKsWMRW34Nn8n2y8=";
      };
    in
    {
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
      # Consumers (e.g. hyprpaper) must enable recursive scanning to
      # walk into the source-attributed subdirectories.
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
          # ".WEB" files (real WebP images) which hyprpaper's extension
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

          runHook postInstall
        '';

        meta = with pkgs.lib; {
          description = "Aggregated catppuccin wallpaper collection (orangci, zhichaoh, daylinmorgan, CozyPixels)";
          license = licenses.mit;
          platforms = platforms.all;
        };
      };
    }
  );
}
