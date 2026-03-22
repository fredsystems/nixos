import ../../../modules/lib/mk-simple-package-module.nix {
  optionPath = "desktop.tradingview";
  description = "TradingView";
  packages = pkgs: [ pkgs.tradingview ];
}
