# Fixture flake for scripts/tests/impacted-hosts-test.sh.
#
# Every output is a `builtins.derivation` that is only ever hashed, never
# built, and each one reads exactly the files it "depends on", so a test can
# change one file and know which outPaths must move:
#
#   hosts/<os>/<name>/marker  that host only
#   modules/common            every host, no dev output
#   dev/shell                 devShells.<system>.default only
#   pkgs/<name>               packages.<system>.<name> only (the overlay case)
{
  outputs =
    _:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems =
        f:
        builtins.listToAttrs (
          map (system: {
            name = system;
            value = f system;
          }) systems
        );
      drv =
        name: text:
        builtins.derivation {
          inherit name text;
          system = "x86_64-linux";
          builder = "/bin/sh";
        };
      host = os: name: {
        config.system.build.toplevel = drv name (
          builtins.readFile (./hosts + "/${os}/${name}/marker") + builtins.readFile ./modules/common
        );
      };
    in
    {
      nixosConfigurations = {
        Alpha = host "linux" "alpha";
        beta = host "linux" "beta";
      };
      darwinConfigurations.mac = host "darwin" "mac";
      devShells = forAllSystems (_: {
        default = drv "shell" (builtins.readFile ./dev/shell);
      });
      packages = forAllSystems (
        _:
        builtins.mapAttrs (name: _: drv name (builtins.readFile (./pkgs + "/${name}"))) (
          builtins.readDir ./pkgs
        )
      );
    };
}
