{
  inputs,
  lib,
  isDarwin,

  catppuccinInput ? inputs.catppuccin,
  ...
}:

let
  isLinux = !isDarwin;
in
{
  imports =
    lib.optional isDarwin inputs.home-manager.darwinModules.default
    ++ lib.optional isDarwin ../services/homebrew.nix
    ++ lib.optional isLinux catppuccinInput.nixosModules.catppuccin
    ++ lib.optional isLinux ../../features
    ++ lib.optional isLinux ../../modules/base/user.nix
    ++ lib.optional isLinux ../../modules/system/kernel-pin.nix
    ++ lib.optional isLinux ./catppuccin.nix;

  nix = {
    settings = {
      substituters = [
        "http://192.168.31.14:8080/fred"
        "https://niri.cachix.org"
        "https://cache.nixos.org"
      ];

      trusted-public-keys = [
        "fred:JjyhvRSvKfkk8r4HS0mS5r5I7dT4GociEFbrR9OgBZ0="
        "niri.cachix.org-1:Wv0OmO7PsuocRKzfDoJ3mulSl7Z6oezYhGhR+3W2964="
      ];

      trusted-users = [
        "root"
        "@wheel"
        "fred"
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
// lib.optionalAttrs isLinux {
  security.sudo.wheelNeedsPassword = false;

  # The goModules fixed-output derivation in nixpkgs includes "GOPROXY" in
  # impureEnvVars, meaning it inherits GOPROXY from the Nix daemon's environment.
  # proxy.golang.org redirects Go module downloads to a GCS bucket
  # (proxy-golang-org-prod) which is geo-restricted ("not available in your
  # location") on this local network.
  # goproxy.cn has its own storage for most modules but falls back to
  # proxy.golang.org (GCS) for uncached entries, which also fails.
  # mirrors.aliyun.com/goproxy/ is backed by Alibaba Cloud OSS (not GCS)
  # and confirmed to serve all required modules directly.
  systemd.services.nix-daemon.environment = {
    GOPROXY = "https://mirrors.aliyun.com/goproxy/";
    GONOSUMDB = "*";
  };
}
