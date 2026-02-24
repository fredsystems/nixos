{
  lib,
  config,
  user,
  extraUsers ? [ ],
  ...
}:
with lib;
let
  cfg = config.desktop;
  username = user;
  allUsers = [ username ] ++ extraUsers;
in
{
  options.desktop = {
    enable = mkOption {
      description = "Enable desktop environment.";
      default = false;
    };

    enable_extra = mkOption {
      description = "Enable extra desktop applications. This will turn on packages that do not work on arm64.";
      default = false;
    };

    enable_games = mkOption {
      description = "Enable games.";
      default = false;
    };

    enable_streaming = mkOption {
      description = "Enable streaming applications.";
      default = false;
    };
  };

  imports = [
    ./environments

    ./1password
    ./alacritty
    ./appimage
    ./audio
    ./brave
    ./discord
    ./firefox
    ./fonts
    ./ghostty
    ./githubdesktop
    ./ladybird
    ./ledger-live
    ./libreoffice
    ./missioncenter
    ./multiviewer
    ./music
    ./obs
    ./print
    ./sqlitebrowser
    ./steam
    ./stockfish
    ./sublimetext
    ./thunderbird
    ./tradingview
    ./trezor
    ./vlc
    ./vscode
    ./wezterm
    ./wireshark
    ./yubikey
    ./zed
  ];

  config = mkIf cfg.enable {
    desktop = {
      environments.enable = true;
      brave.enable = true;
      firefox.enable = true;
      fonts.enable = true;
      ghostty.enable = true;
      print.enable = true;
      githubdesktop.enable = true;
      vscode.enable = true;
      zed.enable = true;
      onepassword.enable = true;
      sqlitebrowser.enable = true;
      sublimetext.enable = true;
      wezterm.enable = true;
      alacritty.enable = true;
      stockfish.enable = true;
      libreoffice.enable = true;
      vlc.enable = true;
      multiviewer.enable = true;
      missioncenter.enable = true;
      audio.enable = true;
      wireshark.enable = true;
      ladybird.enable = true;
      yubikey.enable = true;
      thunderbird.enable = true;
      music.enable = if cfg.enable_extra then true else false;
      appimage.enable = if cfg.enable_extra then true else false;
      discord.enable = if cfg.enable_extra then true else false;
      tradingview.enable = if cfg.enable_extra then true else false;
      steam.enable = if cfg.enable_games then true else false;
      obs.enable = if cfg.enable_streaming then true else false;
      ledger.enable = if cfg.enable_extra then true else false;
      trezor.enable = if cfg.enable_extra then true else false;
    };

    home-manager.users = lib.genAttrs allUsers (_: {
      catppuccin.cursors.enable = true;
    });
  };
}
