# FIXME: mime types
import ../../../modules/lib/mk-simple-package-module.nix {
  optionPath = "desktop.libreoffice";
  description = "LibreOffice";
  packages =
    pkgs: with pkgs; [
      libreoffice-qt
      hunspell
      hunspellDicts.en_US
    ];
  systemWide = true;
}
