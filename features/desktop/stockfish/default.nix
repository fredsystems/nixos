import ../../../modules/lib/mk-simple-package-module.nix {
  optionPath = "desktop.stockfish";
  description = "Stockfish chess engine and Arena GUI";
  packages = pkgs: [
    pkgs.stockfish
    pkgs.arena
  ];
}
