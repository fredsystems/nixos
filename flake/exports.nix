# flake/exports.nix
#
# The flake's nixosModules and homeModules (agent-docs/plans/
# PLAN_04_MODULE_INTERFACES.md, 4.10). Every export evaluates in a bare
# `nixpkgs.lib.nixosSystem` with no specialArgs, in one of two ways:
#
#   * on its own plus `dependencies`, which bundles the third-party modules
#     and overlays this flake's modules use, pinned to this flake's inputs;
#   * on its own plus `overlays` and the consumer's OWN copies of those
#     modules, for a consumer that already has them. Bundling them into every export would
#     make such a consumer fail with "option already declared": Nix
#     de-duplicates only an identical import, and their sops-nix or
#     home-manager is a different one.
#
# So the exports themselves import only modules of this repository: the
# profile or feature, and the modules declaring every option it sets
# (fleet-identity for shared.*, deployment-meta for deployment.*, ...). Those
# never conflict with anything a consumer has.
#
# MODULES.md documents, per export, what it needs from `dependencies`.
{ inputs }:
let
  # Our own option declarations, wherever an export sets them.
  fleetIdentity = [
    ../modules/base/fleet-identity.nix
    ../modules/base/fleet-identity-hm-bridge.nix
  ];
  deploymentMeta = [
    ../modules/base/deployment-meta.nix
    ../modules/base/deployment-meta-linux.nix
  ];
  unfree = [ ../modules/base/nixpkgs-unfree.nix ];

  # The desktop wallpapers are this flake's own package; default to it so a
  # consumer need not, while still being able to set another.
  wallpapers =
    { config, lib, ... }:
    {
      shared.catppuccinWallpapers =
        lib.mkDefault
          inputs.self.packages.${config.nixpkgs.hostPlatform.system}.catppuccin-wallpapers;
    };
  overlays = {
    nixpkgs.overlays = [
      (import ../overlays/default.nix)
      (import ./lib/opencode-overlay.nix inputs)
      inputs.nixos-needsreboot.overlays.default
      (final: _: {
        inherit (inputs.freminal.packages.${final.stdenv.hostPlatform.system}) freminal;
        kernelPinPkgs = import inputs.nixpkgs-kernel {
          inherit (final.stdenv.hostPlatform) system;
          config.allowUnfreePredicate = final.config.allowUnfreePredicate;
        };
      })
    ];
  };
in
{
  nixosModules = {
    # The package overlays this flake's modules read (nixos-needsreboot,
    # opencode, freminal, ...). Part of `dependencies`; import it on its own
    # when you supply the third-party modules yourself. Overlays never
    # conflict with a consumer's own.
    inherit overlays;

    # The third-party modules and overlays the rest of the exports rely on,
    # pinned to this flake's inputs, for a consumer that does not bring its
    # own. Leave it out and supply the same modules yourself if you already
    # use any of them.
    dependencies =
      { config, ... }:
      {
        imports = [
          overlays
          inputs.sops-nix.nixosModules.sops
          inputs.home-manager.nixosModules.home-manager
          inputs.catppuccin.nixosModules.catppuccin
          inputs.nix-flatpak.nixosModules.nix-flatpak
          inputs.niri.nixosModules.niri
        ];

        home-manager.sharedModules = [
          (import ../modules/base/home-catppuccin.nix { inherit (inputs) catppuccin; })
          inputs.nixvim.homeModules.nixvim
          inputs.nix-yazi-plugins.legacyPackages.${config.nixpkgs.hostPlatform.system}.homeManagerModules.default
          inputs.lan-mouse.homeManagerModules.default
          inputs.freminal.homeManagerModules.default
          inputs.frext.homeManagerModules.default
        ];
      };

    desktop-common = {
      imports = [
        ../profiles/desktop.nix
        ../features/desktop
        wallpapers
      ]
      ++ fleetIdentity
      ++ deploymentMeta
      ++ unfree;
    };

    adsb-hub = {
      imports = [ ../profiles/adsb-hub.nix ] ++ fleetIdentity ++ deploymentMeta ++ unfree;
    };

    hardware-profiles = {
      imports = [ ../modules/hardware ] ++ unfree;
    };
    hardware-i2c = {
      imports = [ ../modules/hardware/i2c.nix ] ++ unfree;
    };
    hardware-graphics = {
      imports = [ ../modules/hardware/graphics.nix ] ++ unfree;
    };
    hardware-fingerprint = {
      imports = [ ../modules/hardware/fingerprint.nix ] ++ unfree;
    };
    hardware-u2f = {
      imports = [ ../modules/hardware/u2f.nix ] ++ unfree;
    };
    hardware-rtl-sdr = {
      imports = [ ../modules/hardware/rtl-sdr.nix ] ++ unfree;
    };
    hardware-logitech = {
      imports = [ ../modules/hardware/logitech.nix ] ++ unfree;
    };

    nas-mounts = import ../modules/data/nas-mounts.nix;
    wifi-networks = import ../modules/data/wifi-networks.nix;
    sync-hosts = import ../modules/data/sync-hosts.nix;
    docker-image-pins = import ../modules/data/docker-image-pins.nix;

    github-runners = {
      imports = [
        ../modules/services/github-runners.nix
        ../modules/services/github-runners-linux.nix
      ];
    };

    # Everything above except `dependencies`; add that too unless you supply
    # the third-party modules yourself.
    default = {
      imports = [
        ../profiles/desktop.nix
        ../features/desktop
        ../profiles/adsb-hub.nix
        ../modules/hardware
        ../modules/data/nas-mounts.nix
        ../modules/data/wifi-networks.nix
        ../modules/data/sync-hosts.nix
        ../modules/services/github-runners.nix
        ../modules/services/github-runners-linux.nix
        wallpapers
      ]
      ++ fleetIdentity
      ++ deploymentMeta
      ++ unfree;
    };
  };

  homeModules =
    let
      homeDesktop = {
        imports = [
          ../home-profiles/desktop.nix
          # Declares programs.atticClient, which the profile sets; the
          # builders add it to every user, an export has to bring it.
          ../modules/services/attic/attic_client.nix
        ];
      };
    in
    {
      home-desktop = homeDesktop;
      default = homeDesktop;
    };
}
