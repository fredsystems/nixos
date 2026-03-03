# lib/mk-system.nix
#
# Builds a NixOS system configuration.  Called for both desktop and server
# machines.  Server machines additionally expose `_colmena` so that the
# Colmena output can reuse the same modules / specialArgs without duplication.
#
# Arguments passed in from flake.nix (the "flake-level" bindings that every
# call site shares):
#
#   inputs           – the full flake inputs attrset
#   self             – the flake self reference
#   user             – primary username string
#   verbose_name     – display name string
#   github_email     – GitHub email string
#   github_signing_key – SSH signing key path
#   hmlib            – home-manager.lib
#   agentNodes       – list of monitoring-agent hostnames
#   agentTargets     – list of scrape target strings
#   agentScrapeMap   – attrset of hostname → scrape address
#
# Per-host arguments (all optional — defaults shown):
#
#   hostName             – the machine hostname (required)
#   hmModules        = [] – extra Home Manager modules for the primary user
#   extraModules     = [] – extra NixOS modules appended after the baseline
#   stateVersion     = "24.11"
#   system           = "x86_64-linux"
#   extraUsers       = []
#   pkgsInput        = inputs.nixpkgs          (nixos-unstable)
#   hmInput          = inputs.home-manager     (unstable)
#   catppuccinInput  = inputs.catppuccin       (unstable)
#   sopsNixInput     = inputs.sops-nix         (unstable)
#   isDesktop        = false  – gates the desktop package tree
{
  inputs,
  self,
  user,
  verbose_name,
  github_email,
  github_signing_key,
  hmlib,
  agentNodes,
  agentTargets,
  agentScrapeMap,
  ...
}:
{
  hostName,
  hmModules ? [ ],
  extraModules ? [ ],
  stateVersion ? "24.11",
  system ? "x86_64-linux",
  extraUsers ? [ ],
  pkgsInput ? inputs.nixpkgs,
  hmInput ? inputs.home-manager,
  catppuccinInput ? inputs.catppuccin,
  sopsNixInput ? inputs.sops-nix,
  isDesktop ? false,
}:
let
  _specialArgs = {
    inherit
      inputs
      user
      extraUsers
      verbose_name
      github_email
      github_signing_key
      hmlib
      system
      stateVersion
      agentNodes
      agentTargets
      agentScrapeMap
      isDesktop
      catppuccinInput
      sopsNixInput
      ;

    catppuccinWallpapers = self.packages.${system}.catppuccin-wallpapers;
  };

  _modules = [
    # Set nixpkgs.hostPlatform explicitly (the modern way to declare the
    # target platform). This suppresses the Colmena-specific deprecation
    # warning: "'system' has been renamed to/replaced by
    # 'stdenv.hostPlatform.system'".
    #
    # Root cause: Colmena's eval.nix always calls eval-config.nix with
    # `inherit (npkgs) system`, which in modern nixpkgs injects a module
    # that sets `nixpkgs.system = lib.warn "..." system`. That lib.warn
    # is a lazy thunk — it only fires when `nixpkgs.system` is evaluated.
    # With `nixpkgs.hostPlatform` set here, nixpkgs uses hostPlatform as
    # its source of truth and never evaluates nixpkgs.system → no warning.
    #
    # The regular nixos-rebuild path calls lib.nixosSystem without a
    # `system` argument, so the warning module is never injected there.
    (
      { lib, ... }:
      {
        nixpkgs.hostPlatform = lib.mkDefault system;
        nixpkgs.overlays = [ (import ./../../overlays/default.nix) ];
      }
    )
    ./../../modules/deployment-meta.nix
    ./../../systems-linux/${hostName}/configuration.nix
    ./../../modules/common/system.nix
    hmInput.nixosModules.home-manager
    {
      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;

        users.${user} = {
          # shared HM baseline
          imports = [
            ./../../modules/common/home.nix
            ./../../modules/attic/attic_client.nix
          ]
          ++ hmModules;
        };

        extraSpecialArgs = {
          inherit
            inputs
            self
            user
            verbose_name
            hmlib
            github_email
            github_signing_key
            catppuccinInput
            stateVersion
            system
            ;
          inherit (inputs)
            catppuccin
            apple-fonts
            nixvim
            niri
            ;
        };
      };
    }
  ]
  ++ extraModules;
in
pkgsInput.lib.nixosSystem {
  specialArgs = _specialArgs;
  modules = _modules;
}
# Attach raw modules + args so the `colmena` output can reuse them
# without duplicating the entire module list.
// {
  _colmena = {
    nixpkgs = pkgsInput;
    specialArgs = _specialArgs;
    modules = _modules;
  };
}
