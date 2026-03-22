import ../../../modules/lib/mk-simple-package-module.nix {
  optionPath = "desktop.sqlitebrowser";
  description = "SQLite Browser";
  packages = pkgs: [ pkgs.sqlitebrowser ];
}
