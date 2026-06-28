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
    home.file = {
      ".config/scripts/" = {
        source = ../../dotfiles/.config/scripts;
        recursive = true;
      };

      # Shell-agnostic config shared by BOTH zsh and bash. Single source of
      # truth for env, aliases, functions, and the final step. zsh sources
      # these via thin wrappers in .oh-my-zsh/custom; bash sources them
      # directly (see features/shell/bash).
      ".config/shell/" = {
        source = ../../dotfiles/shell;
        recursive = true;
      };

      ".markdownlint-cli2.yaml" = {
        source = ../../dotfiles/.markdownlint-cli2.yaml;
      };
    };
  });
}
