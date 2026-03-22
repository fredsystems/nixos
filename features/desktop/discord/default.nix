import ../../../modules/lib/mk-simple-package-module.nix {
  optionPath = "desktop.discord";
  description = "Discord";
  packages = pkgs: [ pkgs.discord ];
}
