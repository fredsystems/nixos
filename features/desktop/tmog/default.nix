import ../../../modules/lib/mk-simple-package-module.nix {
  optionPath = "desktop.tmog";
  description = "Task Manager TMOG";
  packages = pkgs: [ pkgs.tmog ];
  unfree = [ "tmog" ];
}
