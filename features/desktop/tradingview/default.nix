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
  cfg = config.desktop.tradingview;
in
{
  options.desktop.tradingview = {
    enable = lib.mkEnableOption "TradingView";
  };

  config = lib.mkIf cfg.enable {
    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        tradingview
      ];
    });
  };
}
