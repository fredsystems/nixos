import ../../../modules/lib/mk-simple-package-module.nix {
  optionPath = "desktop.missioncenter";
  description = "Mission Center";
  packages = pkgs: [ pkgs.mission-center ];
}
