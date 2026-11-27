#!/usr/bin/env bash
#
# update-alarmdotcom.sh -- re-pin corehub's Alarm.com Home Assistant
# integration (hosts/linux/corehub/home-automation/alarmdotcom/pin.json) to
# the latest GitHub release of ibasebcast/ha-alarmdotcom.
#
# The hash is the fetchFromGitHub (NAR) hash of the release tag's source,
# from `nix flake prefetch`. Run by .github/workflows/update-alarmdotcom.yaml,
# which proves the build and opens a PR for review.
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
pin_file="${repo_root}/hosts/linux/corehub/home-automation/alarmdotcom/pin.json"
repo="ibasebcast/ha-alarmdotcom"

die() {
	echo "update-alarmdotcom: $*" >&2
	exit 1
}

[ -f "$pin_file" ] || die "$pin_file not found"

auth=()
[ -n "${GH_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${GH_TOKEN}")
release="$(curl -fsSL "${auth[@]}" "https://api.github.com/repos/${repo}/releases/latest")" ||
	die "could not query the latest release of $repo"

tag="$(jq -er '.tag_name' <<<"$release")" || die "no tag_name in the release"
version="${tag#v}"
# The version is spliced into a tag and a store path, so refuse anything that
# is not a plain dotted version.
[[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "unexpected release tag: $tag"

current="$(jq -er .version "$pin_file")" || die "could not read version from $pin_file"

echo "pinned: $current"
echo "latest: $version"

if [ "$current" = "$version" ]; then
	echo "already up to date"
	exit 0
fi

echo "prefetching github:${repo}/v${version}..."
hash="$(nix flake prefetch --json "github:${repo}/v${version}" | jq -er .hash)" ||
	die "could not prefetch tag v${version}"

tmp="$(mktemp)"
jq -n --arg version "$version" --arg hash "$hash" \
	'{version: $version, hash: $hash}' >"$tmp" || die "could not write pin"
mv "$tmp" "$pin_file" || die "could not replace $pin_file"

echo "updated to $version ($hash)"
exit 2
