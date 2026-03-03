# Server node definitions — single source of truth.
#
# Drives BOTH nixosConfigurations and the colmena topology.
# stateVersion, extraUsers, channel inputs, and deployment metadata
# all live here — one edit propagates everywhere.
#
# To add a server:
#   1. Create systems-linux/<name>/configuration.nix
#   2. Add one entry below — everything else is derived.
#
# Per-entry fields (all optional — defaults shown):
#   stateVersion         = "24.11"
#   extraUsers           = []
#   hmModules            = []
#   extraModules         = []
#   pkgsInput            = nixpkgs-stable        (from inputs)
#   hmInput              = home-manager-stable   (from inputs)
#   catppuccinInput      = catppuccin-stable      (from inputs)
#   sopsNixInput         = sops-nix-stable        (from inputs)
#   targetHost           = "<name>.local"         (colmena SSH target)
#   targetPort           = 22                     (colmena SSH port)
#   tags                 = []                     (colmena node tags)
#   allowLocalDeployment = false                  (colmena)
{
  fredhub = {
    stateVersion = "25.11";
    tags = [ "hub" ];
    allowLocalDeployment = true;
  };

  fredvps = {
    stateVersion = "25.05";
    extraUsers = [ "nik" ];
    extraModules = [
      {
        home-manager.users.nik = {
          imports = [
            ../systems-linux/fredvps/nik-home.nix
          ];
        };
      }
    ];
    targetHost = "fredclausen.com";
    targetPort = 2269;
    tags = [ "vps" ];
  };

  sdrhub = {
    tags = [ "sdr" ];
  };

  acarshub = {
    tags = [ "adsb" ];
  };

  vdlmhub = {
    tags = [ "adsb" ];
  };

  hfdlhub1 = {
    tags = [ "hfdl" ];
  };

  hfdlhub2 = {
    tags = [ "hfdl" ];
  };
}
