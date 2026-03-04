{
  lib,
  pkgs,
  config,
  inputs,
  ...
}:
with lib;
let
  cfg = config.desktop.fonts;
in
{
  options.desktop.fonts = {
    enable = mkOption {
      description = "Install fonts.";
      default = false;
    };
  };

  config = mkIf cfg.enable {
    # environment.systemPackages = [
    #   pkgs.nerdfonts
    #   pkgs.fira-code
    #   pkgs.fira-code-symbols
    # ];

    nixpkgs.config.allowUnfreePredicate =
      pkg:
      builtins.elem (lib.getName pkg) [
        "joypixels"
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
        inputs.apple-fonts.packages.${pkg.system}.sf-pro-nerd
        inputs.apple-fonts.packages.${pkg.system}.ny-nerd
        # corefonts
        # cifs-utils
        # dina-font
        # liberation_ttf
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
