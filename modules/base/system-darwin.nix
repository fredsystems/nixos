# modules/base/system-darwin.nix
#
# Darwin-only half of modules/base/system.nix: imported only by
# flake/lib/mk-darwin-system.nix. mk-system.nix imports
# modules/base/system-linux.nix instead. Both builders still import
# modules/base/system.nix for the config shared by both OSes.
{
  inputs,
  ...
}:
{
  imports = [
    inputs.home-manager.darwinModules.default
    ../services/homebrew.nix
  ];
}
