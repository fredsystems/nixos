import ../../../modules/lib/mk-simple-package-module.nix {
  optionPath = "desktop.photocraft";
  description = "Photocraft";
  packages = pkgs: [ pkgs.photocraft ];
}
