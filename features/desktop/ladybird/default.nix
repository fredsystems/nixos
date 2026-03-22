import ../../../modules/lib/mk-simple-package-module.nix {
  optionPath = "desktop.ladybird";
  description = "Ladybird browser";
  packages = pkgs: [ pkgs.ladybird ];
}
