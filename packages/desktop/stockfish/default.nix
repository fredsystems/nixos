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
  cfg = config.desktop.stockfish;
in
{
  options.desktop.stockfish = {
    enable = mkOption {
      description = "Enable Sublime Text.";
      default = false;
    };
  };

  config = mkIf cfg.enable {
    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        stockfish
        arena
      ];
    });
  };
}
