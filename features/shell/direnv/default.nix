{
  user,
  extraUsers ? [ ],
  lib,
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;
in
{
  config = {
    home-manager.users = lib.genAttrs allUsers (_: {
      programs.direnv = {
        enable = true;
        enableBashIntegration = true;
        enableZshIntegration = true;
        # nix-direnv caches the evaluated devShell derivation and GC-roots
        # it, instead of plain direnv's stdlib `use flake` re-evaluating on
        # every `cd`. Needed for per-project rust-overlay/flake devShells
        # (e.g. providing a Rust toolchain to nvim's rust_analyzer) to load
        # quickly and survive garbage collection.
        nix-direnv.enable = true;
      };
    });
  };
}
