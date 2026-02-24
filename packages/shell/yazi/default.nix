{
  pkgs,
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
    home-manager.users = lib.genAttrs allUsers (_: {
      home.packages = with pkgs; [
        yazi

        # plugins for yazi
        ffmpeg
        p7zip
        jq
        poppler
        fd
        ripgrep
        fzf
        zoxide
        imagemagick
      ];

      programs.yazi = {
        enable = true;
        # FIXME: Remove when all versions of our systems are 26.05 or later
        shellWrapperName = "y";
      };

      catppuccin.yazi.enable = true;
    });
  };
}
