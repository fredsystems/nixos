{
  stateVersion,
  user,
  pkgs,
  ...
}:
let
  username = user;
  homeDir = "/home/${username}";
in
{
  ##########################################################################
  ## HOME BASE SETTINGS (platform-aware)
  ##########################################################################
  home = {
    inherit username;
    homeDirectory = homeDir;
    inherit stateVersion;

    packages = with pkgs; [
      zoxide
      oh-my-zsh
    ];
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
