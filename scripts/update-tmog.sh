#!/usr/bin/env bash
#
# update-tmog.sh -- re-pin overlays/tmog.json to the latest Task Manager
# TMOG Linux x86_64 tarball.
#
# The version comes from upstream's release manifest, the same file TMOG's
# own update check and tmog.org's download cards read. The manifest names
# and hashes the AppImage only, so the tarball URL is derived from the
# version and its hash is prefetched. See overlays/tmog.nix for why the
# tarball and not the AppImage.
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
pin_file="${repo_root}/overlays/tmog.json"
downloads="https://www.tmog.org/downloads"
manifest_url="${downloads}/release-linux.json"

die() {
	echo "update-tmog: $*" >&2
	exit 1
}

[ -f "$pin_file" ] || die "$pin_file not found"

manifest="$(curl -fsSL "$manifest_url")" || die "could not query $manifest_url"

schema="$(jq -er '.schemaVersion' <<<"$manifest")" || die "no schemaVersion in manifest"
[ "$schema" = "1" ] || die "unsupported manifest schemaVersion $schema"

arch="$(jq -er '.architecture' <<<"$manifest")" || die "no architecture in manifest"
[ "$arch" = "x86_64" ] || die "manifest is for $arch, expected x86_64"

version="$(jq -er '.version' <<<"$manifest")" || die "no version in manifest"
# The version is spliced into a URL, so refuse anything that is not a plain
# dotted version.
[[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "unexpected version string: $version"

url="${downloads}/TaskManagerOG-${version}-linux-x86_64.tar.gz"

current_version="$(jq -er .version "$pin_file")" || die "could not read version from $pin_file"
current_url="$(jq -er .url "$pin_file")" || die "could not read url from $pin_file"

echo "pinned: $current_version"
echo "latest: $version"

if [ "$current_version" = "$version" ] && [ "$current_url" = "$url" ]; then
	echo "already up to date"
	exit 0
fi

echo "fetching hash for $url..."
hash="$(nix store prefetch-file --json --hash-type sha256 "$url" | jq -er .hash)" ||
	die "could not prefetch $url (did upstream change the tarball naming?)"

tmp="$(mktemp)"
jq -n --arg version "$version" --arg url "$url" --arg hash "$hash" \
	'{version: $version, url: $url, hash: $hash}' >"$tmp" || die "could not write pin"
mv "$tmp" "$pin_file" || die "could not replace $pin_file"

echo "updated to $version ($hash)"
exit 2
