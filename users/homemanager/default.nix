{
  lib,
  isDarwin,
  stateVersion,
  ...
}:
let
  isLinux = !isDarwin;
in
{
  imports = lib.optional isLinux ./linux-xdg.nix;

  home = {
    inherit stateVersion;
  };
}
