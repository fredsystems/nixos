{
  lib,
  config,
  user,
  extraUsers ? [ ],
  ...
}:
let
  cfg = config.desktop;
  allUsers = [ user ] ++ extraUsers;
in
{
  options.desktop = {
    enable = lib.mkEnableOption "desktop environment";

    enable_extra = lib.mkEnableOption "extra desktop applications (packages that do not work on arm64)";

    enable_games = lib.mkEnableOption "games";

    enable_streaming = lib.mkEnableOption "streaming applications";
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
    ./freminal
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

  config = lib.mkIf cfg.enable {
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
      freminal.enable = true;
      music.enable = cfg.enable_extra;
      appimage.enable = cfg.enable_extra;
      discord.enable = cfg.enable_extra;
      tradingview.enable = cfg.enable_extra;
      steam.enable = cfg.enable_games;
      obs.enable = cfg.enable_streaming;
      ledger.enable = cfg.enable_extra;
      trezor.enable = cfg.enable_extra;
    };

    home-manager.users = lib.genAttrs allUsers (_: {
      catppuccin.cursors.enable = true;
    });
  };
}
