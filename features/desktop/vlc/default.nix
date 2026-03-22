import ../../../modules/lib/mk-simple-package-module.nix {
  optionPath = "desktop.vlc";
  description = "VLC";
  packages = pkgs: [ pkgs.vlc ];
}
