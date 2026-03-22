import ../../../modules/lib/mk-simple-package-module.nix {
  optionPath = "desktop.multiviewer";
  description = "Multiviewer for F1";
  packages = pkgs: [ pkgs.multiviewer-for-f1 ];
}
