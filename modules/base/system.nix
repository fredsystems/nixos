{
  config,
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
    extraOptions = lib.mkIf isLinux ''
      !include ${config.sops.templates."nix-access-tokens.conf".path}
    '';

    settings = {
      substituters = [
        "http://192.168.31.14:8080/fred"
        "https://colmena.cachix.org"
        "https://catppuccin.cachix.org"
        "https://niri.cachix.org"
        "https://niri-epireyn.cachix.org"
        "https://cache.nixos.org"
      ];

      trusted-public-keys = [
        "fred:JjyhvRSvKfkk8r4HS0mS5r5I7dT4GociEFbrR9OgBZ0="
        "colmena.cachix.org-1:7BzpDnjjH8ki2CT3f6GdOk7QAzPOl+1t3LvTLXqYcSg="
        "catppuccin.cachix.org-1:noG/4HkbhJb+lUAdKrph6LaozJvAeEEZj4N732IysmU="
        "niri.cachix.org-1:Wv0OmO7PsuocRKzfDoJ3mulSl7Z6oezYhGhR+3W2964="
        "niri-epireyn.cachix.org-1:tlVyFN7CtsDT+ZcLPS+ekFWeT1X6X4OqvWqbBMyIzFA="
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

  sops.secrets.github_pat = { };

  sops.templates."nix-access-tokens.conf".content = ''
    access-tokens = github.com=${config.sops.placeholder.github_pat}
  '';

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
