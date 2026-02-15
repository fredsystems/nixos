{
  pkgs,
  user,
  ...
}:
let
  username = user;
in
{
  config = {
    home-manager.users.${username} = {
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
    };
  };
}
