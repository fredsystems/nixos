{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.desktop.fonts;
in
{
  options.desktop.fonts = {
    enable = lib.mkEnableOption "fonts";
  };

  config = lib.mkIf cfg.enable {
    # environment.systemPackages = [
    #   pkgs.nerdfonts
    #   pkgs.fira-code
    #   pkgs.fira-code-symbols
    # ];

    # Apple's font licence permits use but not redistribution, so the
    # vendored SF / New York packages (overlays/apple-fonts.nix) are marked
    # unfree and have to be named here explicitly.
    nixpkgsUnfree.allowed = [
      "joypixels"
      "ny-nerd"
      "sf-compact-nerd"
      "sf-mono-nerd"
      "sf-pro-nerd"
    ];
    nixpkgs.config.joypixels.acceptLicense = true;

    fonts = {
      packages = with pkgs; [
        nerd-fonts.meslo-lg
        cascadia-code
        nerd-fonts.caskaydia-mono
        nerd-fonts.caskaydia-cove
        fira-code
        fira-code-symbols
        font-awesome
        noto-fonts
        noto-fonts-cjk-sans
        # noto-fonts-emoji
        # noto-fonts-extra
        twemoji-color-font
        noto-fonts-color-emoji
        google-fonts
        apple-fonts.sf-pro-nerd
        apple-fonts.ny-nerd
        apple-fonts.sf-compact-nerd
        apple-fonts.sf-mono-nerd
        # corefonts
        # cifs-utils
        # dina-font
        liberation_ttf
        # mplus-outline-fonts.githubRelease
        # powerline-fonts
        # proggyfonts
        ubuntu-classic
        # unifont
        # unifont_upper
        joypixels
        font-manager
      ];

      fontconfig = {
        defaultFonts = {
          serif = [
            "NewYork Nerd Font"
          ];
          sansSerif = [
            "SFProDisplay Nerd Font"
            "Ubuntu"
          ];

          # FIXME: do we want Cascadia Code NF instead of Caskaydia Cove?
          monospace = [
            "Caskaydia Cove Nerd Font"
            "Cascadia Code"
            "MesloLGS Nerd Font Mono"
            "Ubuntu Mono"
          ];
          emoji = [
            "Noto Color Emoji"
            "JoyPixels"
          ];
        };
      };

      enableDefaultPackages = true;
      fontconfig.useEmbeddedBitmaps = true;
    };
  };
}
