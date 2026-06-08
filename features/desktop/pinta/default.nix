import ../../../modules/lib/mk-simple-package-module.nix {
  optionPath = "desktop.pinta";
  description = "Pinta";
  packages = pkgs: [ pkgs.pinta ];
}
