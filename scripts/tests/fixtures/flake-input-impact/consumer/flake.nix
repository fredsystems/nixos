{
  description = "flake-input-impact.sh test fixture: consumer";
  inputs = {
    nixpkgs.url = "git+file://@TMPROOT@/fake-nixpkgs";
    dep-follow = {
      url = "git+file://@TMPROOT@/dep-follow";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    dep-owning.url = "git+file://@TMPROOT@/dep-owning";
    dep-source.url = "git+file://@TMPROOT@/dep-source";
  };

  # self, nixpkgs and dep-follow are deliberately not bound below (caught
  # by `...`): dep-follow follows the root's nixpkgs (not owned) and
  # moving it alone must never change any output's outPath (case b:
  # moved-but-unused -> none).
  outputs =
    {
      dep-owning,
      dep-source,
      ...
    }:
    let
      system = builtins.currentSystem;
      # Never built -- only .outPath is ever read -- so the "builder" and
      # "args" below are never exercised. Keeps the fixture flakes free of
      # a real nixpkgs.
      mkDrv =
        name:
        builtins.derivation {
          inherit name system;
          builder = "/bin/sh";
          args = [ ];
        };
    in
    {
      nixosConfigurations.testhost = {
        config.system.build.toplevel = mkDrv "toplevel-${dep-owning.thing}-${dep-source.value}";
      };
      devShells.${system}.default = mkDrv "devshell";
      packages.${system}.a = mkDrv "pkg-a";
    };
}
