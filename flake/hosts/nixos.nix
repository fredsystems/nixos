# NixOS system definitions.
#
# Returns the `nixosConfigurations` flake output.
#
# Arguments closed over from flake.nix:
#   self          — the flake itself (for self.lib.mkSystem)
#   inputs        — all flake inputs (for solaar)
#   nixpkgs-stable, home-manager-stable, catppuccin-stable, sops-nix-stable
#                 — stable-channel inputs used as defaults for server nodes
#   serverNodes   — the canonical server table defined in hosts/servers.nix
{
  self,
  nixpkgs-stable,
  home-manager-stable,
  catppuccin-stable,
  sops-nix-stable,
  serverNodes,
  solaar,
  ...
}:

# ── Desktop machines — unstable channel, not colmena-managed ──────────────────
{
  Daytona = self.lib.mkSystem {
    hostName = "daytona";
    isDesktop = true;
    hmModules = [ ../systems-linux/daytona/home.nix ];
    extraModules = [ solaar.nixosModules.default ];
  };

  maranello = self.lib.mkSystem {
    hostName = "maranello";
    isDesktop = true;
    hmModules = [ ../systems-linux/maranello/home.nix ];
    extraModules = [ solaar.nixosModules.default ];
  };
}

# ── Server machines — derived from serverNodes (hosts/servers.nix) ────────────
// builtins.mapAttrs (
  name: node:
  self.lib.mkSystem {
    hostName = name;
    stateVersion = node.stateVersion or "24.11";
    extraUsers = node.extraUsers or [ ];
    pkgsInput = node.pkgsInput or nixpkgs-stable;
    hmInput = node.hmInput or home-manager-stable;
    catppuccinInput = node.catppuccinInput or catppuccin-stable;
    sopsNixInput = node.sopsNixInput or sops-nix-stable;
    hmModules = node.hmModules or [ ];
    extraModules = node.extraModules or [ ];
  }
) serverNodes
