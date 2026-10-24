{
  user,
  extraUsers ? [ ],
  lib,
  ...
}:

let
  allUsers = [ user ] ++ extraUsers;
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
        # unconditionally is an eval error there. Gate on the option
        # existing; drop the gate once servers move to 26.11.
        // lib.optionalAttrs (options.programs.nushell ? loadSessionVariables) {
          loadSessionVariables = true;
        };

        catppuccin.nushell.enable = true;
      }
    );
  };
}
