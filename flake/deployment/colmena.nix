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
#   github_email — git identity string
#   hmlib        — home-manager lib
#   agentNodes, agentScrapeMap — monitoring topology
#   desktopNodes, desktopScrapeMap — desktop monitoring topology (consumed by
#     prometheus.nix on the master; harmless on agent nodes that import the
#     same module set)
{
  inputs,
  self,
  serverNodes,
  ...
}:
let
  inherit (inputs)
    nixpkgs
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
      imports = c.modules ++ [
        # Restore the flake-derived version metadata that nixpkgs' own
        # `lib.nixosSystem` injects but Colmena's evaluator does not.
        #
        # nixpkgs' flake builds its `lib` as
        #   (import ./lib).extend (import ./lib/flake-version-info.nix self)
        # and that overlay rewrites `lib.trivial.versionSuffix` and
        # `revisionWithDefault` from the flake's own `self`. `lib.nixosSystem`
        # passes that extended lib into eval-config, so `mkSystem` (which calls
        # `pkgsInput.lib.nixosSystem`) gets `26.05.<date>.<shortRev>`. Colmena
        # calls eval-config directly with the plain `pkgs.lib` from
        # `import nixpkgs { }`, which is NOT flake-extended, so the suffix fell
        # back to the sentinel `pre-git`.
        #
        # The consequence was that `colmena apply` and
        # `nix eval .#nixosConfigurations.<host>` produced DIFFERENT store paths
        # for the same host and the same commit. Two things broke as a result:
        #
        #   * The fleet manifest is generated from nixosConfigurations, so every
        #     colmena-deployed server compared as `unmanaged` forever -- its
        #     running closure was a path the manifest could never contain.
        #   * ci-linux.yaml builds and pushes
        #     `.#nixosConfigurations.<host>...toplevel` to Attic, but colmena
        #     deployed a different path, so the cache never had the closure
        #     colmena actually wanted. Every `colmena apply` rebuilt the servers
        #     locally instead of substituting from Attic.
        #
        # Setting these three options makes the two evaluation paths produce
        # byte-identical toplevels (verified for all seven servers), which fixes
        # both. Keep them in sync with whatever nixpkgs' flake-version-info
        # overlay does if that upstream mechanism changes.
        #
        # NOTE: `system.nixos.revision` here is the NIXPKGS revision, not this
        # flake's. It only changes when flake.lock's nixpkgs changes, which
        # already changes the closure, so this does not reintroduce the
        # "never bake the flake's git rev into a closure" problem documented in
        # flake/lib/mk-system.nix.
        {
          system.nixos.versionSuffix = ".${
            builtins.substring 0 8 c.nixpkgs.lastModifiedDate
          }.${c.nixpkgs.shortRev}";
          system.nixos.revision = c.nixpkgs.rev;
          nixpkgs.flake.source = c.nixpkgs.outPath;
        }
      ];
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

      # `inputs` is the only module argument, as in mkSystem. Everything that
      # used to differ per node (stateVersion, extraUsers, channel inputs)
      # lives in the module list mkNode reuses from mkSystem, so the deploy
      # path enforces exactly the contract `nix eval` does: mkSystem
      # format-checks stateVersion and sets system.stateVersion itself.
      specialArgs = { inherit inputs; };
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
