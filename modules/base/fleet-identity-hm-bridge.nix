{ config, ... }:
{
  # Home Manager is a separate module system and cannot see the system's
  # `config.shared.*`; this copies the values into every Home Manager user's
  # configuration. home.stateVersion is not bridged: modules/base/home-base.nix
  # still sets it from the builder.
  home-manager.sharedModules = [
    ./fleet-identity-home.nix
    {
      shared = {
        user = {
          inherit (config.shared.user) name fullName email;
        };
        hostSystem = config.nixpkgs.hostPlatform.system;
      };
    }
  ];
}
