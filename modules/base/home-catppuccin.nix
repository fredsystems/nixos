# modules/base/home-catppuccin.nix
#
# catppuccin's home-manager module, plus the settings that depend on which
# catppuccin input a host uses. Applied by both builders as
# `import ./home-catppuccin.nix { catppuccin = <input>; }` and added to
# home-manager.sharedModules, so the stable / unstable choice lives only in
# the builder. The user-facing settings (enable, flavor, accent) stay in
# ./home.nix.
{ catppuccin }:
{ lib, pkgs, ... }:
{
  imports = [ catppuccin.homeModules.catppuccin ];

  catppuccin = {
    # catppuccin's flake module defaults `sources` to its own packages
    # (built from its pinned nixpkgs, served by catppuccin.cachix.org), but
    # as ONE whole-set mkDefault: any normal-priority
    # `catppuccin.sources.<port>` definition discards it, and catppuccin
    # then rebuilds EVERY port with our pkgs. Restating the default per
    # port means a single-port override only replaces that port.
    #
    # The fallback costs cache misses and local builds. On Darwin it is
    # worse: several ports (starship, bottom, palette, ...)
    # importTOML/importJSON their source -- import-from-derivation -- so
    # any eval of a Darwin host on a non-Darwin machine needs those
    # aarch64-darwin outputs substitutable and dies with "platform
    # mismatch" otherwise. A per-port lazygit override did exactly that on
    # #2644, back when CI's find-darwin job ran on Linux.
    sources = builtins.mapAttrs (
      _: lib.mkDefault
    ) catppuccin.packages.${pkgs.stdenv.hostPlatform.system};
  };
}
