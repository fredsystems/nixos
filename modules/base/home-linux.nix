{
  config,
  lib,
  options,
  ...
}:
let
  user = config.shared.user.name;
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
    # mkDefault: shared.user.name itself defaults to home.username, so a
    # normal-priority definition here would be circular for a standalone
    # Home Manager consumer with no bridge. With the bridge the value is the
    # same either way.
    username = lib.mkDefault user;
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
