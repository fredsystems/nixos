{
  config,
  lib,
  ...
}:
let
  allUsers = config.shared.allUsers;
in
{
  config = {
    home-manager.users = lib.genAttrs allUsers (_: {
      # Enable Oh-my-zsh
      programs.zsh.oh-my-zsh = {
        enable = true;
        extraConfig = ''
          HIST_STAMPS="yyyy-mm-dd"
          HYPHEN_INSENSITIVE="true"
          zstyle ':omz:plugins:alias-finder' autoload yes
        '';
        plugins = [
          "git"
          "history-substring-search"
          "colored-man-pages"
          # "zsh-autosuggestions"
          # "zsh-syntax-highlighting"
          "sudo"
          "copyfile"
          "copybuffer"
          "copypath"
          "history"
          "extract"
          "fancy-ctrl-z"
          "systemd"
          "alias-finder"
          "dirhistory"
        ];
      };
    });
  };
}
