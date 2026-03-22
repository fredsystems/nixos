{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.desktop.libreoffice;
in
{
  options.desktop.libreoffice = {
    enable = lib.mkEnableOption "LibreOffice";
  };

  # FIXME: mime types

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      libreoffice-qt
      hunspell
      hunspellDicts.en_US
    ];
  };
}
