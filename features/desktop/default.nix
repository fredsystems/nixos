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
    ./frext
    ./ghostty
    ./githubdesktop
    ./kitty
    ./ladybird
    ./ledger-live
    ./libreoffice
    ./missioncenter
    ./multiviewer
    ./music
    ./obs
    ./pinta
    ./print
    ./sqlitebrowser
    ./steam
    ./stockfish
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
      alacritty.enable = true;
      appimage.enable = cfg.enable_extra;
      audio.enable = true;
      brave.enable = true;
      discord.enable = cfg.enable_extra;
      environments.enable = true;
      firefox.enable = true;
      fonts.enable = true;
      freminal.enable = true;
      frext.enable = true;
      ghostty.enable = true;
      githubdesktop.enable = true;
      kitty.enable = true;
      ladybird.enable = true;
      ledger.enable = cfg.enable_extra;
      libreoffice.enable = true;
      missioncenter.enable = true;
      multiviewer.enable = true;
      music.enable = cfg.enable_extra;
      obs.enable = cfg.enable_streaming;
      onepassword.enable = true;
      pinta.enable = true;
      print.enable = true;
      sqlitebrowser.enable = true;
      steam.enable = cfg.enable_games;
      stockfish.enable = true;
      thunderbird.enable = true;
      tradingview.enable = cfg.enable_extra;
      trezor.enable = cfg.enable_extra;
      vlc.enable = true;
      vscode.enable = true;
      wezterm.enable = true;
      wireshark.enable = true;
      yubikey.enable = true;
      zed.enable = true;
    };

    home-manager.users = lib.genAttrs allUsers (_: {
      catppuccin.cursors.enable = true;
      # FIXME(catppuccin-nix-cursors-pointerCursor-enable): WORKAROUND, not a
      # fix. The catppuccin cursors home-manager module sets `home.pointerCursor`
      # (name/package) without setting `home.pointerCursor.enable`, so
      # home-manager falls back to its deprecated "non-null implies enabled"
      # path and emits an `evaluation warning:` that fails our CI. Setting
      # `.enable` explicitly here silences it. Upstream fix in flight:
      # catppuccin/nix#1003. Delete this line once that lands in a catppuccin
      # release our flake follows. Tracked by
      # .github/workflows/track-upstream-fixes.yaml.
      home.pointerCursor.enable = true;
    });
  };
}
