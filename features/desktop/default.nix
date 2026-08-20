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
      clipboard.enable = true;
      discord.enable = cfg.enable_extra;
      environments.enable = true;
      firefox.enable = true;
      flatpak.enable = true;
      fonts.enable = true;
      freminal.enable = true;
      frext.enable = true;
      ghostty.enable = true;
      githubdesktop.enable = true;
      kitty.enable = true;
      # FIXME(nixpkgs-ladybird-cve-2026-58592): see
      # .github/tracked-upstream-fixes.json. nixpkgs marks
      # ladybird-0-unstable-2026-06-05 insecure, which is a hard eval failure
      # on both desktops. Disabled rather than added to
      # permittedInsecurePackages: this is a browser, so the CVE is directly
      # reachable by untrusted input.
      ladybird.enable = false;
      # No `lan-mouse.enable` line here on purpose, unlike every other entry
      # in this block. It pairs one specific machine with one specific peer
      # sitting at one specific edge of that machine's monitor layout, so
      # there is no fleet-wide default that would be correct -- enabling it
      # here would put a phantom screen edge on Daytona, whose desk has no
      # second computer beyond it. Hosts opt in individually; see
      # hosts/linux/maranello/configuration.nix.
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
      # The catppuccin cursors module sets `home.pointerCursor` (name/package)
      # but not `home.pointerCursor.enable`, so home-manager falls back to its
      # deprecated "non-null implies enabled" path and emits an
      # `evaluation warning:` that fails our CI. home-manager expects this key
      # to be set explicitly, so we do so here regardless of upstream.
      home.pointerCursor.enable = true;
    });
  };
}
