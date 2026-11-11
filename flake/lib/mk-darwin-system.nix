# lib/mk-darwin-system.nix
#
# Factory function for nix-darwin configurations.
# Called from flake.nix as: self.lib.mkDarwinSystem { ... }
#
# The outer call (from flake.nix) injects shared flake-level bindings.
# The inner call (per machine) takes the host-specific arguments.
#
# All module paths are relative to the flake root (two levels up from here).
{
  inputs,
  darwin,
  home-manager,
  catppuccin,
  nix-yazi-plugins,
  user,
  verbose_name,
  github_email,
  ...
}:

{
  hostName,
  hmModules ? [ ],
  extraModules ? [ ],
  stateVersion,
  system ? "aarch64-darwin",
}:
let

  # Same contract as mkSystem, which had a format guard while this path had
  # none. On Darwin this value feeds home-manager's home.stateVersion only --
  # nix-darwin's own system.stateVersion is a small integer set in
  # profiles/darwin.nix -- but a typo is just as wrong here. Raised in review
  # on PR #2243.
  checkedStateVersion =
    import ./check-state-version.nix "mkDarwinSystem: host '${hostName}'"
      stateVersion;
in
darwin.lib.darwinSystem {
  # `inputs` is the only module argument; see mk-system.nix.
  specialArgs = { inherit inputs; };

  modules = [
    (_: {
      nixpkgs.overlays = [
        (import ./../../overlays/default.nix)
        (import ./opencode-overlay.nix inputs)
        # freminal from its own flake (features/desktop/freminal reads
        # pkgs.freminal); mk-system.nix applies the same overlay.
        (final: _: {
          inherit (inputs.freminal.packages.${final.stdenv.hostPlatform.system}) freminal;
        })
      ];
      networking.hostName = hostName;
    })
    # Fleet data as options; see modules/base/fleet-identity.nix. Darwin has
    # no extra users, no monitoring topology and no wallpapers; the options'
    # defaults cover the rest.
    (_: {
      shared.user = {
        name = user;
        fullName = verbose_name;
        email = github_email;
      };

      # mkDefault: a host can still give one Home Manager user (e.g. an extra
      # user) its own home.stateVersion without a conflicting definition.
      home-manager.sharedModules = [
        ({ lib, ... }: { home.stateVersion = lib.mkDefault checkedStateVersion; })
        # External home-manager modules; mk-system.nix wires the same set.
        (import ../../modules/base/home-catppuccin.nix { inherit catppuccin; })
        inputs.nixvim.homeModules.nixvim
        nix-yazi-plugins.legacyPackages.${system}.homeManagerModules.default
        # For hosts that import features/desktop/lan-mouse (the Mac Studio);
        # inert where programs.lan-mouse stays disabled.
        inputs.lan-mouse.homeManagerModules.default
      ];
    })
    ../../modules/base/deployment-meta.nix
    # sops-nix's own Darwin module. Wired here rather than from
    # modules/secrets/sops.nix so that file does not need to choose between
    # nixosModules.sops and darwinModules.sops; mk-system.nix wires the Linux
    # half the same way.
    inputs.sops-nix.darwinModules.sops
    ../../modules/base/system.nix
    # Darwin-only half of modules/base/system.nix (Home Manager's Darwin
    # module, homebrew.nix); see that file's own header. mk-system.nix
    # imports modules/base/system-linux.nix instead.
    ../../modules/base/system-darwin.nix
    ../../hosts/darwin/${hostName}/configuration.nix
    home-manager.darwinModules.home-manager

    {
      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;

        users.${user} = {
          imports = [
            ../../modules/base/home.nix
            ../../modules/services/attic/attic_client.nix
          ]
          ++ hmModules;

          # `enable`, `flavor`, `accent`, and (when present on the input)
          # `autoEnable` are set by ../../modules/base/home.nix. Only the
          # NixOS-side system module sets `enable = true` automatically;
          # Darwin needs it set explicitly here at the HM level.
          catppuccin.enable = true;
        };

        extraSpecialArgs = { inherit inputs; };
      };

      # Darwin Nix settings
      nix = {
        optimise.automatic = true;
        settings.experimental-features = [
          "nix-command"
          "flakes"
        ];
      };
    }
  ]
  ++ extraModules;
}
