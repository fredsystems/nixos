{
  inputs,
  lib,
  system,
  ...
}:

let
  isDarwin = lib.hasSuffix "darwin" system;
  isLinux = !isDarwin;
in
{
  imports =
    lib.optional isDarwin inputs.home-manager.darwinModules.default
    ++ lib.optional isDarwin ../homebrew.nix
    # Linux-only NixOS modules
    ++ lib.optional isLinux inputs.catppuccin.nixosModules.catppuccin
    ++ lib.optional isLinux ../../packages
    ++ lib.optional isLinux ../../users
    ++ lib.optional isLinux ./linux-catpuccin.nix;

  nix = {
    settings = {
      substituters = [
        "http://192.168.31.14:8080/fred"
        "https://cache.nixos.org"
      ];

      trusted-public-keys = [
        "fred:JjyhvRSvKfkk8r4HS0mS5r5I7dT4GociEFbrR9OgBZ0="
      ];

      experimental-features = [
        "nix-command"
        "flakes"
      ];
    };

    gc = {
      automatic = true;
      options = "--delete-older-than 7d";
    };
    optimise.automatic = true;
  };
}
