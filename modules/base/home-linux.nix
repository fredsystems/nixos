{
  user,
  ...
}:
let
  homeDir = "/home/${user}";
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
    };

    mimeApps.enable = true;
  };

  fonts.fontconfig.enable = true;
}
