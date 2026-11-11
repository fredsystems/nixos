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
let
  # home-manager renamed `programs.gemini-cli` to `programs.antigravity-cli`.
  # The release-25.11 catppuccin input (server hosts) still ships a functional
  # `gemini-cli` module that sets the now-renamed `programs.gemini-cli` option,
  # tripping a fatal "option has been renamed" evaluation warning. Setting
  # `catppuccin.gemini-cli.enable = false` suppresses it there. The unstable
  # catppuccin input (desktop/darwin) replaced that module with a
  # `mkRemovedOptionModule` stub, so *defining* the option there is a fatal
  # assertion. Detect which variant is present by reading the module source:
  # the functional module references `programs.gemini-cli`, the stub does not.
  geminiCliModule = "${catppuccin}/modules/home-manager/gemini-cli.nix";
  catppuccinHasFunctionalGeminiCli =
    builtins.pathExists geminiCliModule
    && lib.hasInfix "programs.gemini-cli" (builtins.readFile geminiCliModule);
in
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
  }
  // lib.optionalAttrs catppuccinHasFunctionalGeminiCli {
    # See `geminiCliModule` above: only disable where the functional module
    # exists (stable). On unstable it is a removed-option stub and defining
    # it would be a fatal assertion.
    gemini-cli.enable = false;
  };
}
