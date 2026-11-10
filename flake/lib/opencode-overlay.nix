# OpenCode 2 from the `opencode` flake input. Lives here rather than in
# overlays/default.nix because that file is a plain overlay with no access to
# the flake inputs.
#
# Upstream pins the node_modules fixed-output hash per system in
# nix/hashes.json, but the bot PR that updates it is regularly left unmerged
# when a release is tagged, so a release can ship with a stale hash and break
# every host that installs opencode. opencode-node-modules-hashes.json holds
# the real hash for those systems, written by
# scripts/opencode-node-modules-hash.sh (run automatically on Renovate's
# opencode PRs by renovate-relock.yaml). An entry only applies to the exact
# opencode revision it was computed for, so a stale entry is inert once the pin
# moves and needs no manual cleanup.
inputs: final: _:
let
  inherit (final.stdenv.hostPlatform) system;
  upstream = inputs.opencode.packages.${system}.opencode;
  pinned = builtins.fromJSON (builtins.readFile ./opencode-node-modules-hashes.json);
  hash = if pinned.rev == inputs.opencode.rev then pinned.nodeModules.${system} or null else null;
in
{
  opencode =
    if hash == null then
      upstream
    else
      upstream.overrideAttrs {
        node_modules = upstream.node_modules.override { inherit hash; };
      };
}
