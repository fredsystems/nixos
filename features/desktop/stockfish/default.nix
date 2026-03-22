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
  cfg = config.desktop.stockfish;
in
{
  options.desktop.stockfish = {
    enable = lib.mkEnableOption "Stockfish chess engine and Arena GUI";
  };

  config = lib.mkIf cfg.enable {
    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        stockfish
        arena
      ];
    });
  };
}
