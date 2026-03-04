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
  cfg = config.desktop.ladybird;
in
{
  options.desktop.ladybird = {
    enable = mkOption {
      description = "Install Ladybird browser.";
      default = false;
    };
  };

  config = mkIf cfg.enable {
    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        ladybird
      ];
    });
  };
}
