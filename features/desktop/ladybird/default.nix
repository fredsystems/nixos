{
  lib,
  pkgs,
  config,
  user,
  extraUsers ? [ ],
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;
  cfg = config.desktop.ladybird;
in
{
  options.desktop.ladybird = {
    enable = lib.mkEnableOption "Ladybird browser";
  };

  config = lib.mkIf cfg.enable {
    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        ladybird
      ];
    });
  };
}
