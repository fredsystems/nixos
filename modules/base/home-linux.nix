{
  user,
  lib,
  options,
  ...
}:
let
  # This module is only ever imported when isLinux (see modules/base/home.nix),
  # so isDarwin is hardcoded rather than threaded through as an argument.
  homeDir = import ../lib/home-dir.nix {
    username = user;
    isDarwin = false;
  };
in
{
  ##########################################################################
  ## HOME BASE SETTINGS — Linux Only
  ##########################################################################
  home = {
    username = user;
    homeDirectory = homeDir;
  };

  ##########################################################################
  ## XDG + FONTS — Linux Only
  ##########################################################################
  xdg = {
    enable = true;

    userDirs = {
      enable = true;
      createDirectories = false;
    }
    // lib.optionalAttrs (options.xdg.userDirs ? setSessionVariables) {
      setSessionVariables = true;
    };

    mimeApps.enable = true;
  };

  fonts.fontconfig.enable = true;
}
