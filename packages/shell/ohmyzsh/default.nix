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
        oh-my-zsh
        zoxide
      ];

      # Enable Oh-my-zsh
      programs.zsh.oh-my-zsh = {
        enable = true;
        plugins = [
          "git"
          "history-substring-search"
          "colored-man-pages"
          # "zsh-autosuggestions"
          # "zsh-syntax-highlighting"
          "sudo"
          "copyfile"
          "copybuffer"
          "history"
          "zoxide"
        ];
      };
    });
  };
}
