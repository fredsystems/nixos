{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.desktop.libreoffice;
in
{
  options.desktop.libreoffice = {
    enable = mkOption {
      description = "Enable LibreOffice.";
      default = false;
    };
  };

  # FIXME: mime types

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      libreoffice-qt
      hunspell
      hunspellDicts.en_US
    ];
  };
}
