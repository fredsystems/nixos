# Darwin system definitions.
#
# Arguments are passed from flake.nix via callPackage-style invocation:
#   darwinConfigurations = import ./flake/hosts/darwin.nix { inherit self; };
{
  self,
  freminal,
  frext,
  ...
}:
{
  "Freds-MacBook-Pro" = self.lib.mkDarwinSystem {
    hostName = "Freds-MacBook-Pro";
    stateVersion = "25.05";
    hmModules = [
      ../../hosts/darwin/Freds-MacBook-Pro/home.nix
      freminal.homeManagerModules.default
      frext.homeManagerModules.default
    ];
  };

  "Freds-Mac-Studio" = self.lib.mkDarwinSystem {
    hostName = "Freds-Mac-Studio";
    stateVersion = "25.05";
    hmModules = [
      ../../hosts/darwin/Freds-Mac-Studio/home.nix
      freminal.homeManagerModules.default
      frext.homeManagerModules.default
    ];
  };
}
