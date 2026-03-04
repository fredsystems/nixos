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
  imports = lib.optional isLinux ./xdg.nix;

  home = {
    inherit stateVersion;
  };
}
