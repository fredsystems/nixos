#!/usr/bin/env bash
#
# sync-syncclipboard.sh -- keep the SyncClipboard server and client pinned to
# the same upstream release.
#
# WHY THIS EXISTS
#
# SyncClipboard ships the server and every desktop client from a single
# upstream tag, but they land in two different places in this repo:
#
#     modules/data/docker-image-pins.nix   the server, as a Docker image
#     overlays/syncclipboard.nix           the Linux client, as an AppImage
#
# Only the first is visible to Renovate (its custom regex manager matches
# every `<key> = "repo:tag@sha256:digest";` entry in
# modules/data/docker-image-pins.nix, and docker updates automerge).
# Nothing watches the overlay. Left alone, Renovate would walk the server
# forward on its own while the client stayed put.
#
# HOW BADLY THAT WOULD ACTUALLY BREAK THINGS
#
# Usually not at all, and it is worth being precise about why rather than
# cargo-culting a lockstep rule. Upstream states compatibility as a *minimum*
# server version, not an exact one:
#
#     v3.1.1-beta3  "requires server version v3.1.1-beta3 or above"
#     v3.1.1-beta4  "server version must be v3.1.1-beta4 or above"
#
# So the contract is `server >= client`, and Renovate moving the server ahead
# is the safe direction. The failure mode that matters is a client newer than
# its server, which no automation here can cause.
#
# The exception is real but rare: v3.1.1 was a hard break in both directions
# ("all clients and independently-deployed servers in the sync network must be
# upgraded together") because it reworked the account system and the wire
# protocol. One such break in the 3.x series so far, and it was announced only
# in prose in Changes.md -- nothing machine-readable separates "additive server
# release" from "protocol changed".
#
# Holding the two equal is therefore a deliberate over-constraint. It costs
# nothing, because both artifacts come from the same tag and there is no
# version the server could usefully be on that the client could not, and it
# replaces "read the changelog and reason about it" with "CI already checked".
#
# EXIT CODES
#
#   0  already in sync, nothing written
#   2  files were updated
#   1  error
#
# Deliberately mirrors sync-opencode-hash.sh so workflows can treat both the
# same way.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
overlay="${repo_root}/overlays/syncclipboard.nix"
pins_file="${repo_root}/modules/data/docker-image-pins.nix"

image_name="jericx/syncclipboard-server"
pins_key="syncclipboard"
appimage_url_base="https://github.com/Jeric-X/SyncClipboard/releases/download"

die() {
  echo "sync-syncclipboard: $*" >&2
  exit 1
}

target_version="${1:-}"
if [ -z "$target_version" ]; then
  target_version="$(gh api repos/Jeric-X/SyncClipboard/releases/latest --jq .tag_name)" ||
    die "could not resolve the latest upstream release"
fi
# Accept either "v3.2.0" or "3.2.0" from the caller; the overlay stores the
# bare version and the image tag carries the v.
version="${target_version#v}"
tag="v${version}"

current_version="$(sed -n 's/^\s*version = "\(.*\)";/\1/p' "$overlay" | head -1)"
current_image="$(sed -n 's|.*'"${pins_key}"' = "'"${image_name}"':\([^"]*\)".*|\1|p' "$pins_file" | head -1)"

[ -n "$current_version" ] || die "could not read the pinned version from $overlay"
[ -n "$current_image" ] || die "could not read the pinned image from $pins_file"

echo "overlay version: $current_version"
echo "image pin:       $current_image"
echo "target:          $tag"

# The AppImage hash and the image digest are both content addresses, so they
# are re-resolved even when the version has not moved. An upstream re-tag or a
# rebuilt image would otherwise leave a pin that no longer matches reality.
appimage_url="${appimage_url_base}/${tag}/SyncClipboard_linux_x64.AppImage"
echo "fetching AppImage hash..."
appimage_hash="$(nix store prefetch-file --json --hash-type sha256 "$appimage_url" | jq -r .hash)" ||
  die "could not prefetch $appimage_url"

echo "fetching image digest..."
digest="$(skopeo inspect --no-tags "docker://docker.io/${image_name}:${tag}" --format '{{.Digest}}')" ||
  die "could not inspect docker://docker.io/${image_name}:${tag}"

case "$digest" in
  sha256:*) ;;
  *) die "unexpected digest format: $digest" ;;
esac

new_image="${tag}@${digest}"
echo "resolved image:  $new_image"
echo "resolved hash:   $appimage_hash"

changed=0

# Overlay: version and hash.
if [ "$current_version" != "$version" ] || ! grep -qF "$appimage_hash" "$overlay"; then
  sed -i \
    -e "s|^\(\s*version = \"\).*\(\";\)$|\1${version}\2|" \
    -e "s|^\(\s*hash = \"\).*\(\";\)$|\1${appimage_hash}\2|" \
    "$overlay"
  changed=1
fi

# Host config: image tag and digest.
if [ "$current_image" != "$new_image" ]; then
  sed -i "s|${pins_key} = \"${image_name}:[^\"]*\";|${pins_key} = \"${image_name}:${new_image}\";|" "$pins_file"
  changed=1
fi

if [ "$changed" -eq 0 ]; then
  echo "already in sync"
  exit 0
fi

# Re-read rather than trusting the sed, so a silently non-matching pattern is
# caught here instead of at eval time in CI.
after_version="$(sed -n 's/^\s*version = "\(.*\)";/\1/p' "$overlay" | head -1)"
after_image="$(sed -n 's|.*'"${pins_key}"' = "'"${image_name}"':\([^"]*\)".*|\1|p' "$pins_file" | head -1)"
[ "$after_version" = "$version" ] || die "overlay version did not update (got '$after_version')"
[ "$after_image" = "$new_image" ] || die "image pin did not update (got '$after_image')"
grep -qF "$appimage_hash" "$overlay" || die "overlay hash did not update"

echo "updated to $tag"
exit 2
