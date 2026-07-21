# lib/mk-darwin-system.nix
#
# Factory function for nix-darwin configurations.
# Called from flake.nix as: self.lib.mkDarwinSystem { ... }
#
# The outer call (from flake.nix) injects shared flake-level bindings.
# The inner call (per machine) takes the host-specific arguments.
#
# All module paths are relative to the flake root (two levels up from here).
{
  inputs,
  self,
  darwin,
  home-manager,
  catppuccin,
  nix-yazi-plugins,
  nixvim,
  user,
  verbose_name,
  github_email,
  github_signing_key,
  hmlib,
  ...
}:

{
  hostName,
  hmModules ? [ ],
  extraModules ? [ ],
  stateVersion ? "25.05",
  system ? "aarch64-darwin",
}:
let
  isDarwin = true;
in
darwin.lib.darwinSystem {
  specialArgs = {
    inherit
      inputs
      self
      system
      user
      verbose_name
      github_email
      github_signing_key
      hmlib
      stateVersion
      ;

    inherit isDarwin;
    sopsNixInput = inputs.sops-nix;
    catppuccinInput = catppuccin;
    nixYaziPluginsInput = nix-yazi-plugins;
    extraUsers = [ ];
  };

  modules = [
    (_: {
      nixpkgs.overlays = [ (import ./../../overlays/default.nix) ];
      networking.hostName = hostName;
    })
    ../../modules/base/deployment-meta.nix
    ../../modules/base/system.nix
    ../../hosts/darwin/${hostName}/configuration.nix
    home-manager.darwinModules.home-manager

    {
      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;

        users.${user} = {
          imports = [
            ../../modules/base/home.nix
            ../../modules/services/attic/attic_client.nix
          ]
          ++ hmModules;

          # `enable`, `flavor`, `accent`, and (when present on the input)
          # `autoEnable` are set by ../../modules/base/home.nix. Only the
          # NixOS-side system module sets `enable = true` automatically;
          # Darwin needs it set explicitly here at the HM level.
          catppuccin.enable = true;
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
            catppuccin
            nixvim
            stateVersion
            isDarwin
            ;
          catppuccinInput = catppuccin;
          nixYaziPluginsInput = nix-yazi-plugins;
        };
      };

      # Darwin Nix settings
      nix = {
        optimise.automatic = true;
        settings.experimental-features = [
          "nix-command"
          "flakes"
        ];
      };
    }
  ]
  ++ extraModules;
}
