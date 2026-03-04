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
  imports = [
    ./bat
    ./direnv
    ./eza
    ./fastfetch
    ./fd
    ./fzf
    ./gh-dash
    ./lazydocker
    ./lazygit
    ./lsd
    ./ohmyzsh
    ./nvim
    # FIXME: pay respects appears to be fucked. It kills the terminal
    ./pay-respects
    ./starship
    ./tmux
    ./yazi
    ./zoxide
    ./zsh
  ];

  home-manager.users = lib.genAttrs allUsers (_: {
    home.file.".config/scripts/" = {
      source = ../../dotfiles/.config/scripts;
      recursive = true;
    };

    home.file.".markdownlint-cli2.yaml" = {
      source = ../../dotfiles/.markdownlint-cli2.yaml;
    };
  });
}
