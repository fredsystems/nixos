import ../../../modules/lib/mk-simple-package-module.nix {
  optionPath = "desktop.vscode";
  description = "Visual Studio Code";
  packages = pkgs: [ pkgs.vscode ];
}
