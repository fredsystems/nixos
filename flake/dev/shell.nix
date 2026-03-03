# Dev shell — available via `nix develop` from the flake root.
#
# Provides:
#   - pre-commit hooks (nixfmt, statix, deadnix, shellcheck, etc.)
#   - nodejs + typescript (for any JS tooling in the repo)
#   - colmena CLI (matched to the colmenaHive evaluator version)
#
# Arguments are the flake-level bindings passed in from flake.nix.
{
  inputs,
  self,
  colmena,
  forAllSystems,
  ...
}:
let
  inherit (inputs) nixpkgs;
in
{
  devShells = forAllSystems (
    system:
    let
      pkgs = import nixpkgs { inherit system; };
      inherit (self.checks.${system}.pre-commit-check) shellHook enabledPackages;
    in
    {
      default = pkgs.mkShell {
        buildInputs =
          enabledPackages
          ++ (with pkgs; [
            nodejs
            nodePackages.typescript
            # Use the binary from the colmena flake input so the CLI version
            # matches the evaluator used by colmenaHive (not pkgs.colmena
            # from nixpkgs, which is shadowed by the flake input attrset).
            colmena.packages.${system}.colmena
          ]);

        shellHook = ''
          # Run git-hooks.nix setup (creates .pre-commit-config.yaml)
          ${shellHook}
        '';
      };
    }
  );
}
