# NixOS system definitions.
#
# Returns the `nixosConfigurations` flake output.
#
# Arguments closed over from flake.nix:
#   self          — the flake itself (for self.lib.mkSystem)
#   inputs        — all flake inputs
#   nixpkgs-stable, home-manager-stable, catppuccin-stable, sops-nix-stable,
#   nix-yazi-plugins-stable
#                 — stable-channel inputs used as defaults for server nodes
#   serverNodes   — the canonical server table defined in hosts/servers.nix
{
  self,
  nixpkgs-stable,
  home-manager-stable,
  catppuccin-stable,
  sops-nix-stable,
  nix-yazi-plugins-stable,
  serverNodes,
  niri,
  freminal,
  frext,
  nix-flatpak,
  ...
}:

# ── Desktop machines — unstable channel, not colmena-managed ──────────────────
{
  Daytona = self.lib.mkSystem {
    hostName = "daytona";
    stateVersion = "24.11";
    isDesktop = true;
    isLaptop = true;
    hmModules = [
      ../../hosts/linux/daytona/home.nix
      freminal.homeManagerModules.default
      frext.homeManagerModules.default
    ];
    extraModules = [
      niri.nixosModules.niri
      nix-flatpak.nixosModules.nix-flatpak
    ];
  };

  maranello = self.lib.mkSystem {
    hostName = "maranello";
    stateVersion = "24.11";
    isDesktop = true;
    # wayle is not focus-aware: OSD/notification popups are pinned to the
    # bottom-left monitor of the 2x2 grid (connector DP-3, EDID "ASUSTek
    # COMPUTER INC VG27A SALMQS105752"). See hosts/linux/maranello/monitors.nix
    # for the full physical layout.
    wayleMonitor = "DP-3";
    hmModules = [
      ../../hosts/linux/maranello/home.nix
      freminal.homeManagerModules.default
      frext.homeManagerModules.default
    ];
    extraModules = [
      niri.nixosModules.niri
      nix-flatpak.nixosModules.nix-flatpak
    ];
  };
}

# ── Server machines — derived from serverNodes (hosts/servers.nix) ────────────
// builtins.mapAttrs (
  name: node:
  self.lib.mkSystem {
    hostName = name;
    # No `or` fallback, deliberately: a node that forgets stateVersion must
    # fail loudly rather than silently inherit one. See flake/lib/mk-system.nix.
    inherit (node) stateVersion;
    extraUsers = node.extraUsers or [ ];
    pkgsInput = node.pkgsInput or nixpkgs-stable;
    hmInput = node.hmInput or home-manager-stable;
    catppuccinInput = node.catppuccinInput or catppuccin-stable;
    sopsNixInput = node.sopsNixInput or sops-nix-stable;
    nixYaziPluginsInput = node.nixYaziPluginsInput or nix-yazi-plugins-stable;
    hmModules = node.hmModules or [ ];
    extraModules = node.extraModules or [ ];
  }
) serverNodes
