import ../../../modules/lib/mk-simple-package-module.nix {
  optionPath = "desktop.music";
  description = "Music";
  packages = pkgs: [ pkgs.cider3 ];
}
