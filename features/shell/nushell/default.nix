{
  config,
  lib,
  ...
}:

let
  allUsers = config.shared.allUsers;
  channelGates = import ../../../modules/lib/channel-gates.nix;
in
{
  config = {
    home-manager.users = lib.genAttrs allUsers (
      _:
      { options, ... }:
      {
        programs.nushell = {
          enable = true;
        }
        # home-manager 26.11 added `loadSessionVariables` with a
        # stateVersion-dependent default and warns (fatal in CI) until it is
        # set explicitly. Servers still use home-manager-stable (26.05),
        # which does not have the option at all, so setting it
        # unconditionally is an eval error there. Channel gate
        # `nushell-load-session-variables` (modules/lib/channel-gates.nix);
        # the `channel-gates` flake check says when to drop it.
        // lib.optionalAttrs (channelGates.available "nushell-load-session-variables" options) {
          loadSessionVariables = true;
        };

        catppuccin.nushell.enable = true;
      }
    );
  };
}
