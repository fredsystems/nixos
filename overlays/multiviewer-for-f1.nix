# MultiViewer for F1 -- nixpkgs' derivation, re-pointed at a newer release.
#
# nixpkgs is stuck at 2.8.4 and cannot move on its own: its updateScript
# builds the download URL from a numeric `id` in the releases API, and the
# API now returns `id: null` with a tokenised URL instead
# (releases.multiviewer.app/v/<version>/1/<token>/multiviewer_<version>_amd64.deb).
# r-ryantm therefore never proposes a bump.
#
# Only `version` and `src` are replaced. The deb layout (usr/lib/multiviewer,
# usr/share/{applications,pixmaps}) is unchanged as of 2.12.0, so nixpkgs'
# unpack/install phases, runtime deps and Wayland wrapper flags are reused.
# If a future release changes the layout, the daily
# update-multiviewer.yaml build step fails before a PR is opened.
#
# The pin lives in multiviewer-for-f1.json so scripts/update-multiviewer.sh
# can rewrite it with jq rather than sed.
#
# Self-retiring: once nixpkgs ships a version >= the pin, prev is used
# untouched, so this never downgrades. Delete this overlay, the JSON, the
# script and the workflow once nixpkgs' updater is fixed and keeping up.
#
# Usage in overlays/default.nix:
#   multiviewer-for-f1 = final.callPackage ./multiviewer-for-f1.nix {
#     inherit (prev) multiviewer-for-f1;
#   };
{
  lib,
  fetchurl,
  multiviewer-for-f1,
}:
let
  pin = lib.importJSON ./multiviewer-for-f1.json;
in
if lib.versionAtLeast multiviewer-for-f1.version pin.version then
  multiviewer-for-f1
else
  multiviewer-for-f1.overrideAttrs (_: {
    inherit (pin) version;
    src = fetchurl {
      inherit (pin) url hash;
    };
  })
