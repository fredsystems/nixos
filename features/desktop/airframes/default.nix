# pkgs.airframes-desktop comes from the airframes-desktop flake's overlay,
# which both builders apply. System-wide so nix-darwin links the .app into
# /Applications/Nix Apps.
import ../../../modules/lib/mk-simple-package-module.nix {
  optionPath = "desktop.airframes";
  description = "Airframes.io desktop app";
  packages = pkgs: [ pkgs.airframes-desktop ];
  systemWide = true;
  unfree = [ "airframes-desktop" ];
}
