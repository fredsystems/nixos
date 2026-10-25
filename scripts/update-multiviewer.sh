#!/usr/bin/env bash
#
# update-multiviewer.sh -- re-pin overlays/multiviewer-for-f1.json to the
# latest MultiViewer for F1 Linux .deb.
#
# The releases API at api.multiviewer.app is the only machine-readable
# source: download URLs carry a per-release token, so they cannot be
# derived from the version number. See overlays/multiviewer-for-f1.nix for
# why nixpkgs' own updater cannot do this.
#
# Requires curl, jq and nix on PATH.
#
# EXIT CODES
#
#   0  already up to date, nothing written
#   2  pin file was updated
#   1  error

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pin_file="${repo_root}/overlays/multiviewer-for-f1.json"
api_url="https://api.multiviewer.app/api/v1/releases/latest/"

die() {
	echo "update-multiviewer: $*" >&2
	exit 1
}

[ -f "$pin_file" ] || die "$pin_file not found"

latest="$(curl -fsSL "$api_url")" || die "could not query $api_url"

version="$(jq -er '.version' <<<"$latest")" || die "no version in API response"
url="$(jq -er '[.downloads[] | select(.platform == "linux_deb") | .url] | first' <<<"$latest")" ||
	die "no linux_deb download in API response"

case "$url" in
https://releases.multiviewer.app/*) ;;
*) die "unexpected download host: $url" ;;
esac

current_version="$(jq -er .version "$pin_file")" || die "could not read version from $pin_file"
current_url="$(jq -er .url "$pin_file")" || die "could not read url from $pin_file"

echo "pinned: $current_version"
echo "latest: $version"

# The URL is compared too: upstream re-publishing the same version under a
# new token is a real change and needs a fresh hash.
if [ "$current_version" = "$version" ] && [ "$current_url" = "$url" ]; then
	echo "already up to date"
	exit 0
fi

echo "fetching hash for $url..."
hash="$(nix store prefetch-file --json --hash-type sha256 "$url" | jq -er .hash)" ||
	die "could not prefetch $url"

tmp="$(mktemp)"
jq -n --arg version "$version" --arg url "$url" --arg hash "$hash" \
	'{version: $version, url: $url, hash: $hash}' >"$tmp" || die "could not write pin"
mv "$tmp" "$pin_file"

echo "updated to $version ($hash)"
exit 2
