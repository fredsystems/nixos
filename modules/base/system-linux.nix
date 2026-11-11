# modules/base/system-linux.nix
#
# Linux-only half of modules/base/system.nix: imported only by
# flake/lib/mk-system.nix. mk-darwin-system.nix imports
# modules/base/system-darwin.nix instead. Both builders still import
# modules/base/system.nix for the config shared by both OSes.
#
# Applied by mk-system.nix as `import ./system-linux.nix { inherit isDesktop; }`
# and passed on to features/default.nix; see that file for why.
{
  isDesktop ? false,
}:
{
  config,
  inputs,

  catppuccinInput ? inputs.catppuccin,
  ...
}:
{
  imports = [
    catppuccinInput.nixosModules.catppuccin
    (import ../../features { inherit isDesktop; })
    ../../modules/base/user.nix
    ../../modules/system/kernel-pin.nix
    ./catppuccin.nix
    ./journald.nix
  ];

  nix.extraOptions = ''
    !include ${config.sops.templates."nix-access-tokens.conf".path}
  '';

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
