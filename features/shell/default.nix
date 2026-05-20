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
    ./bash
    ./bat
    ./direnv
    ./eza
    ./fastfetch
    ./fd
    ./fish
    ./fzf
    ./gh-dash
    ./lazydocker
    ./lazygit
    ./lazynpm
    ./lsd
    ./nushell
    ./nvim
    ./ohmyzsh
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
