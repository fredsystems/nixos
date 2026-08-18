# Server node definitions — single source of truth.
#
# Drives BOTH nixosConfigurations and the colmena topology.
# stateVersion, extraUsers, channel inputs, and deployment metadata
# all live here — one edit propagates everywhere.
#
# To add a server:
#   1. Create hosts/linux/<name>/configuration.nix
#   2. Add one entry below — everything else is derived.
#
# Per-entry fields (all optional — defaults shown):
#   stateVersion         – REQUIRED, no default (see flake/lib/mk-system.nix)
#   extraUsers           = []
#   hmModules            = []
#   extraModules         = []
#   pkgsInput            = nixpkgs-stable        (from inputs)
#   hmInput              = home-manager-stable   (from inputs)
#   catppuccinInput      = catppuccin-stable      (from inputs)
#   sopsNixInput         = sops-nix-stable        (from inputs)
#   nixYaziPluginsInput  = nix-yazi-plugins-stable (from inputs)
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
            ../../hosts/linux/fredvps/nik-home.nix
          ];
        };
      }
    ];
    targetHost = "fredclausen.com";
    targetPort = 2269;
    tags = [ "vps" ];
  };

  sdrhub = {
    stateVersion = "24.11";
    tags = [ "sdr" ];
  };

  acarshub = {
    stateVersion = "24.11";
    tags = [ "adsb" ];
  };

  vdlmhub = {
    stateVersion = "24.11";
    tags = [ "adsb" ];
  };

  hfdlhub1 = {
    stateVersion = "24.11";
    tags = [ "hfdl" ];
  };

  hfdlhub2 = {
    stateVersion = "24.11";
    tags = [ "hfdl" ];
  };

  nvrhub = {
    stateVersion = "26.05";
    # Freshly provisioned; mDNS/AdGuard resolution for nvrhub.local is only
    # published once this host has deployed once, so colmena targets the
    # literal LAN address until then.
    targetHost = "192.168.31.179";
    tags = [ "nvr" ];
  };
}
