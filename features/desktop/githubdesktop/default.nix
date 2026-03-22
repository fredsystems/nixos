import ../../../modules/lib/mk-simple-package-module.nix {
  optionPath = "desktop.githubdesktop";
  description = "GitHub Desktop";
  packages = pkgs: [ pkgs.github-desktop ];
}
