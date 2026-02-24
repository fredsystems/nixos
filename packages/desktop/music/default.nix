{
  lib,
  pkgs,
  config,
  user,
  extraUsers ? [ ],
  ...
}:
with lib;
let
  allUsers = [ user ] ++ extraUsers;
  cfg = config.desktop.music;
  cider2 = import ./cider.nix {
    inherit pkgs;
  };
in
{
  options.desktop.music = {
    # Updated to match the new configuration
    enable = mkOption {
      description = "Enable Music";
      default = false;
    };
  };

  config = mkIf cfg.enable {
    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        cider2
      ];
    });
  };
}
