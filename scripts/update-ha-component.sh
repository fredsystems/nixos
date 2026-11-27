#!/usr/bin/env bash
#
# update-ha-component.sh COMPONENT -- re-pin one of corehub's packaged Home
# Assistant custom integrations
# (hosts/linux/corehub/home-automation/COMPONENT/pin.json) to the latest
# GitHub release of the repo its pin names.
#
# The hash is the fetchFromGitHub (NAR) hash of the release tag's source,
# from `nix flake prefetch`. Run by .github/workflows/update-ha-components.yaml,
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

die() {
	echo "update-ha-component: $*" >&2
	exit 1
}

component="${1:-}"
[[ "$component" =~ ^[a-z0-9_]+$ ]] || die "usage: $0 COMPONENT (a directory under hosts/linux/corehub/home-automation)"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pin_file="${repo_root}/hosts/linux/corehub/home-automation/${component}/pin.json"

[ -f "$pin_file" ] || die "$pin_file not found"
repo="$(jq -er .repo "$pin_file")" || die "no repo in $pin_file"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "unexpected repo in $pin_file: $repo"

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
jq -n --arg repo "$repo" --arg version "$version" --arg hash "$hash" \
	'{repo: $repo, version: $version, hash: $hash}' >"$tmp" || die "could not write pin"
mv "$tmp" "$pin_file" || die "could not replace $pin_file"

echo "updated to $version ($hash)"
exit 2
