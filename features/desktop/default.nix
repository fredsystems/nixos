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
    ./chatgpt
    ./clipboard
    ./discord
    ./firefox
    ./flatpak
    ./fonts
    ./freminal
    ./frext
    ./ghostty
    ./githubdesktop
    ./kitty
    ./ladybird
    ./lan-mouse
    ./ledger-live
    ./libreoffice
    ./missioncenter
    ./multiviewer
    ./music
    ./nix-ld
    ./obs
    ./photocraft
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
      alacritty.enable = lib.mkDefault true;
      appimage.enable = lib.mkDefault cfg.enable_extra;
      audio.enable = lib.mkDefault true;
      brave.enable = lib.mkDefault true;
      chatgpt.enable = lib.mkDefault true;
      clipboard.enable = lib.mkDefault true;
      discord.enable = lib.mkDefault cfg.enable_extra;
      environments.enable = lib.mkDefault true;
      firefox.enable = lib.mkDefault true;
      flatpak.enable = lib.mkDefault true;
      fonts.enable = lib.mkDefault true;
      freminal.enable = lib.mkDefault true;
      frext.enable = lib.mkDefault true;
      ghostty.enable = lib.mkDefault true;
      githubdesktop.enable = lib.mkDefault true;
      kitty.enable = lib.mkDefault true;
      ladybird.enable = lib.mkDefault true;
      # No `lan-mouse.enable` line here on purpose, unlike every other entry
      # in this block. It pairs one specific machine with one specific peer
      # sitting at one specific edge of that machine's monitor layout, so
      # there is no fleet-wide default that would be correct -- enabling it
      # here would put a phantom screen edge on Daytona, whose desk has no
      # second computer beyond it. Hosts opt in individually; see
      # hosts/linux/maranello/configuration.nix.
      ledger.enable = lib.mkDefault cfg.enable_extra;
      libreoffice.enable = lib.mkDefault true;
      missioncenter.enable = lib.mkDefault true;
      multiviewer.enable = lib.mkDefault true;
      music.enable = lib.mkDefault cfg.enable_extra;
      nix-ld.enable = lib.mkDefault true;
      obs.enable = lib.mkDefault cfg.enable_streaming;
      onepassword.enable = lib.mkDefault true;
      photocraft.enable = lib.mkDefault true;
      pinta.enable = lib.mkDefault true;
      print.enable = lib.mkDefault true;
      sqlitebrowser.enable = lib.mkDefault true;
      steam.enable = lib.mkDefault cfg.enable_games;
      stockfish.enable = lib.mkDefault true;
      thunderbird.enable = lib.mkDefault true;
      tradingview.enable = lib.mkDefault cfg.enable_extra;
      trezor.enable = lib.mkDefault cfg.enable_extra;
      vlc.enable = lib.mkDefault true;
      vscode.enable = lib.mkDefault true;
      wezterm.enable = lib.mkDefault true;
      wireshark.enable = lib.mkDefault true;
      yubikey.enable = lib.mkDefault true;
      zed.enable = lib.mkDefault true;
    };

    home-manager.users = lib.genAttrs allUsers (_: {
      catppuccin.cursors.enable = true;
      # The catppuccin cursors module sets `home.pointerCursor` (name/package)
      # but not `home.pointerCursor.enable`, so home-manager falls back to its
      # deprecated "non-null implies enabled" path and emits an
      # `evaluation warning:` that fails our CI. home-manager expects this key
      # to be set explicitly, so we do so here regardless of upstream.
      home.pointerCursor.enable = true;
    });
  };
}
