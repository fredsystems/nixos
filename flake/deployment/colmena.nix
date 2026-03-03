# Colmena deployment topology — server-only.
#
# Desktop machines (Daytona, maranello) and Darwin machines are intentionally
# excluded here; manage those locally with nixos-rebuild / darwin-rebuild.
#
# Usage:
#   colmena apply                        # deploy all servers
#   colmena apply --on '@stable'         # deploy all stable servers
#   colmena apply --on fredhub           # deploy one server
#   colmena apply --on '@adsb'           # deploy by tag
#   colmena build                        # dry-run / build only
#
# Arguments (passed from flake.nix):
#   inputs       — flake inputs attrset
#   self         — the flake's self reference
#   serverNodes  — canonical server node table from flake/hosts/servers.nix
#   user         — primary username string
#   verbose_name — display name string
#   github_email, github_signing_key — git identity strings
#   hmlib        — home-manager lib
#   agentNodes, agentTargets, agentScrapeMap — monitoring topology
{
  inputs,
  self,
  serverNodes,
  user,
  verbose_name,
  github_email,
  github_signing_key,
  hmlib,
  agentNodes,
  agentTargets,
  agentScrapeMap,
  ...
}:
let
  inherit (inputs)
    nixpkgs
    catppuccin-stable
    sops-nix-stable
    ;

  # The colmena flake input — renamed to avoid clashing with the `colmena`
  # output attribute name defined at the bottom of this file.
  colmenaFlake = inputs.colmena;

  # Shadow the deprecated `pkgs.system` alias (warnAlias since 2025-10-28) so
  # Colmena's `inherit (npkgs) system` in eval.nix doesn't fire the
  # "'system' has been renamed to/replaced by 'stdenv.hostPlatform.system'"
  # warning. Colmena always calls evalConfig { inherit (npkgs) system; ... }
  # which forces npkgs.system — overriding it with the non-alias value
  # pkgs.stdenv.hostPlatform.system avoids the lazy warn thunk entirely.
  withShadowedSystem = pkgs: pkgs // { inherit (pkgs.stdenv.hostPlatform) system; };

  # Build one Colmena node attrset from a (name, serverNode) pair.
  # Reuses the exact module list assembled by lib.mkSystem so there is no
  # duplication between nixosConfigurations and the colmena topology.
  mkNode =
    name: node:
    let
      c = self.nixosConfigurations.${name}._colmena;
    in
    {
      deployment = {
        targetHost = node.targetHost or "${name}.local";
        targetPort = node.targetPort or 22;
        targetUser = "fred";
        buildOnTarget = false;
        allowLocalDeployment = node.allowLocalDeployment or false;
        tags = [
          "server"
          "stable"
        ]
        ++ (node.tags or [ ]);
      };
      imports = c.modules;
    };

  # The raw colmena hive attrset.  colmenaHive (below) wraps this with
  # colmena.lib.makeHive for direct nix-eval-based deployment.
  hive = {
    meta = {
      # Fallback nixpkgs (used for Colmena internals; each node overrides
      # via nodeNixpkgs so this is rarely the active pkgs for a build).
      nixpkgs = withShadowedSystem (import nixpkgs { system = "x86_64-linux"; });

      # Per-node nixpkgs derived from the channel each node was built with.
      # Changing pkgsInput in serverNodes automatically propagates here.
      nodeNixpkgs = builtins.mapAttrs (
        name: _:
        let
          pkgs = import self.nixosConfigurations.${name}._colmena.nixpkgs { system = "x86_64-linux"; };
        in
        withShadowedSystem pkgs
      ) serverNodes;

      # Shared specialArgs forwarded to every node as true specialArgs
      # (bypasses the NixOS option system — no infinite-recursion risk).
      specialArgs = {
        inherit
          inputs
          user
          verbose_name
          github_email
          github_signing_key
          hmlib
          agentNodes
          agentTargets
          agentScrapeMap
          ;
        system = "x86_64-linux";
        isDesktop = false;
        # Conservative defaults; overridden per-node in nodeSpecialArgs.
        stateVersion = "24.11";
        extraUsers = [ ];
        catppuccinInput = catppuccin-stable;
        sopsNixInput = sops-nix-stable;
        catppuccinWallpapers = self.packages."x86_64-linux".catppuccin-wallpapers;
      };

      # Per-node overrides derived from the serverNodes table.
      # Channel-sensitive args (catppuccinInput, sopsNixInput) are read from
      # the node entry so they stay in sync with the nixosConfigurations
      # channel selection automatically.
      nodeSpecialArgs = builtins.mapAttrs (_: node: {
        stateVersion = node.stateVersion or "24.11";
        extraUsers = node.extraUsers or [ ];
        catppuccinInput = node.catppuccinInput or catppuccin-stable;
        sopsNixInput = node.sopsNixInput or sops-nix-stable;
      }) serverNodes;
    };
  }
  // builtins.mapAttrs mkNode serverNodes;
in
{
  # Raw hive attrset — kept for direct inspection and legacy use.
  colmena = hive;

  # colmenaHive uses colmena.lib.makeHive for direct nix eval based deployment
  # (replaces the old nix-instantiate / builtins.getFlake path).
  colmenaHive = colmenaFlake.lib.makeHive hive;
}
