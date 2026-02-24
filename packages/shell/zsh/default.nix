{
  lib,
  pkgs,
  user,
  extraUsers ? [ ],
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;
in
{
  config = {
    home-manager.users = lib.genAttrs allUsers (
      uname:
      let
        homeDir =
          if pkgs.stdenv.isDarwin then
            "/Users/${uname}/.oh-my-zsh/custom"
          else
            "/home/${uname}/.oh-my-zsh/custom";
      in
      { config, ... }:
      {

        programs.zsh = {
          enable = true;
          enableCompletion = true;
          history.size = 10000;

          syntaxHighlighting.enable = true;
          autosuggestion.enable = true;

          # ${config.xdg.configHome}/zsh"
          dotDir = if pkgs.stdenv.isDarwin then config.home.homeDirectory else "${config.xdg.configHome}/zsh";

          # Example override
          shellAliases = {
            ls = lib.mkForce "${pkgs.lsd}/bin/lsd -la";
          };

          # Instead of initContent, use initExtra so we can source files
          initContent = lib.mkMerge [
            # EARLY INIT – env, paths
            (lib.mkOrder 500 ''
              source ${homeDir}/00-env.zsh
            '')

            # TMUX must come before OMZ
            (lib.mkOrder 900 ''
              source ${homeDir}/15-tmux.zsh
            '')

            # ZLE before completion
            (lib.mkOrder 550 ''
              source ${homeDir}/20-zle.zsh
            '')

            # MAIN CONFIG – aliases, fzf, functions
            (lib.mkOrder 1000 ''
              source ${homeDir}/10-aliases.zsh
              source ${homeDir}/30-fzf.zsh
              source ${homeDir}/40-functions.zsh
            '')

            # FINAL
            (lib.mkOrder 1500 ''
              source ${homeDir}/90-final.zsh
            '')
          ];

        };

        # zsh-syntax-highlighting theme
        catppuccin.zsh-syntax-highlighting.enable = true;

        # Install your custom Zsh module files
        home.file.".oh-my-zsh/custom".source = ../../../dotfiles/.oh-my-zsh/custom;
      }
    );
  };
}
