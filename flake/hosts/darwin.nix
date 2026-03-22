# Darwin system definitions.
#
# Arguments are passed from flake.nix via callPackage-style invocation:
#   darwinConfigurations = import ./flake/hosts/darwin.nix { inherit self; };
{
  self,
  ...
}:
{
  "Freds-MacBook-Pro" = self.lib.mkDarwinSystem {
    hostName = "Freds-MacBook-Pro";
    hmModules = [ ../../hosts/darwin/Freds-MacBook-Pro/home.nix ];
  };

  "Freds-Mac-Studio" = self.lib.mkDarwinSystem {
    hostName = "Freds-Mac-Studio";
    hmModules = [ ../../hosts/darwin/Freds-Mac-Studio/home.nix ];
  };
}
