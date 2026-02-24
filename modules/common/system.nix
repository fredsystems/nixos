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

  # The goModules fixed-output derivation in nixpkgs includes "GOPROXY" in
  # impureEnvVars, meaning it inherits GOPROXY from the Nix daemon's environment.
  # proxy.golang.org redirects Go module downloads to a GCS bucket
  # (proxy-golang-org-prod) which is geo-restricted ("not available in your
  # location") on this local network.
  # goproxy.cn has its own storage for most modules but falls back to
  # proxy.golang.org (GCS) for uncached entries, which also fails.
  # mirrors.aliyun.com/goproxy/ is backed by Alibaba Cloud OSS (not GCS)
  # and confirmed to serve all required modules directly.
  systemd.services.nix-daemon.environment = lib.optionalAttrs isLinux {
    GOPROXY = "https://mirrors.aliyun.com/goproxy/";
    GONOSUMDB = "*";
  };
}
