# lib/mk-system.nix
#
# Builds a NixOS system configuration.  Called for both desktop and server
# machines.  Server machines additionally expose `_colmena` so that the
# Colmena output can reuse the same modules / specialArgs without duplication.
#
# Arguments passed in from flake.nix (the "flake-level" bindings that every
# call site shares):
#
#   inputs           – the full flake inputs attrset
#   self             – the flake self reference
#   user             – primary username string
#   verbose_name     – display name string
#   github_email     – GitHub email string
#   hmlib            – home-manager.lib
#   agentNodes       – list of monitoring-agent hostnames
#   agentScrapeMap   – attrset of hostname → scrape address
#   desktopNodes     – list of desktop hostnames
#   desktopScrapeMap – attrset of desktop hostname → scrape address
#
# Per-host arguments (all optional — defaults shown):
#
#   hostName             – the machine hostname (required)
#   hmModules        = [] – extra Home Manager modules for the primary user
#   extraModules     = [] – extra NixOS modules appended after the baseline
#   stateVersion         – REQUIRED, no default. See the note below.
#   system           = "x86_64-linux"
#   extraUsers       = []
#   pkgsInput        = inputs.nixpkgs          (nixos-unstable)
#   hmInput          = inputs.home-manager     (unstable)
#   catppuccinInput  = inputs.catppuccin       (unstable)
#   sopsNixInput     = inputs.sops-nix         (unstable)
#   nixYaziPluginsInput = inputs.nix-yazi-plugins (unstable)
#   kernelPkgsInput  = inputs.nixpkgs-kernel   (server kernel pin source;
#                                               unused on desktops)
#   isDesktop        = false  – gates the desktop package tree
{
  inputs,
  self,
  user,
  verbose_name,
  github_email,
  hmlib,
  agentNodes,
  agentScrapeMap,
  desktopNodes,
  desktopScrapeMap,
  ...
}:
{
  hostName,
  hmModules ? [ ],
  extraModules ? [ ],
  stateVersion,
  system ? "x86_64-linux",
  extraUsers ? [ ],
  pkgsInput ? inputs.nixpkgs,
  hmInput ? inputs.home-manager,
  catppuccinInput ? inputs.catppuccin,
  sopsNixInput ? inputs.sops-nix,
  nixYaziPluginsInput ? inputs.nix-yazi-plugins,
  kernelPkgsInput ? inputs.nixpkgs-kernel,
  isDesktop ? false,
}:
let
  isDarwin = pkgsInput.lib.hasSuffix "darwin" system;

  # stateVersion is required and format-checked. The validator is shared with
  # mkDarwinSystem and colmena so the three construction paths cannot drift
  # into enforcing different contracts. See flake/lib/check-state-version.nix.
  checkedStateVersion = import ./check-state-version.nix "mkSystem: host '${hostName}'" stateVersion;

  _specialArgs = {
    inherit
      inputs
      user
      extraUsers
      verbose_name
      github_email
      hmlib
      system
      agentNodes
      agentScrapeMap
      desktopNodes
      desktopScrapeMap
      isDesktop
      catppuccinInput
      sopsNixInput
      nixYaziPluginsInput
      kernelPkgsInput
      isDarwin
      ;
    stateVersion = checkedStateVersion;

    catppuccinWallpapers = self.packages.${system}.catppuccin-wallpapers;
  };

  _modules = [
    # Set nixpkgs.hostPlatform explicitly (the modern way to declare the
    # target platform). This suppresses the Colmena-specific deprecation
    # warning: "'system' has been renamed to/replaced by
    # 'stdenv.hostPlatform.system'".
    #
    # Root cause: Colmena's eval.nix always calls eval-config.nix with
    # `inherit (npkgs) system`, which in modern nixpkgs injects a module
    # that sets `nixpkgs.system = lib.warn "..." system`. That lib.warn
    # is a lazy thunk — it only fires when `nixpkgs.system` is evaluated.
    # With `nixpkgs.hostPlatform` set here, nixpkgs uses hostPlatform as
    # its source of truth and never evaluates nixpkgs.system → no warning.
    #
    # The regular nixos-rebuild path calls lib.nixosSystem without a
    # `system` argument, so the warning module is never injected there.
    (
      { lib, ... }:
      {
        nixpkgs.hostPlatform = lib.mkDefault system;
        nixpkgs.overlays = [
          (import ./../../overlays/default.nix)
          (import ./opencode-overlay.nix inputs)
          inputs.nixos-needsreboot.overlays.default
          # Exposes the kernel-pin nixpkgs tree (see modules/system/kernel-pin.nix)
          # as pkgs.kernelPinPkgs, importing kernelPkgsInput once per host with
          # only the fleet's unfree predicate threaded through.
          (final: _: {
            kernelPinPkgs = import kernelPkgsInput {
              inherit (final.stdenv.hostPlatform) system;
              config.allowUnfreePredicate = final.config.allowUnfreePredicate;
            };
          })
        ];
      }
    )
    # Fleet data as options; see modules/base/fleet-identity.nix.
    {
      shared = {
        user = {
          name = user;
          fullName = verbose_name;
          email = github_email;
        };
        inherit extraUsers;
        monitoring = {
          inherit
            agentNodes
            agentScrapeMap
            desktopNodes
            desktopScrapeMap
            ;
        };
        catppuccinWallpapers = self.packages.${system}.catppuccin-wallpapers;
      };

      system.stateVersion = checkedStateVersion;
      # mkDefault: a host can still give one Home Manager user (e.g. an extra
      # user) its own home.stateVersion without a conflicting definition.
      home-manager.sharedModules = [
        ({ lib, ... }: { home.stateVersion = lib.mkDefault checkedStateVersion; })
      ];
    }
    ./../../modules/base/deployment-meta.nix
    # Linux-only half of deployment-meta.nix (systemd-specific assertions and
    # the tailscale-address-drift unit); see that file's own header. Not
    # imported by mk-darwin-system.nix.
    ./../../modules/base/deployment-meta-linux.nix
    # sops-nix's own NixOS module. Wired here rather than from
    # modules/secrets/sops.nix so that file does not need to choose between
    # nixosModules.sops and darwinModules.sops; mk-darwin-system.nix wires the
    # Darwin half the same way.
    sopsNixInput.nixosModules.sops
    # Fleet-wide facts about the home network. Declares options only, so being
    # in every host's module set costs nothing; the two hosts that read it
    # (fredvps's ignoreIP, sdrhub's drift check) must agree on one value, and
    # this is where that value lives.
    ./../../modules/data/home-network.nix
    ./../../hosts/linux/${hostName}/configuration.nix
    ./../../modules/base/system.nix
    # Linux-only half of modules/base/system.nix (features/, catppuccin's
    # nixosModule, the kernel pin, etc.); see that file's own header.
    # mk-darwin-system.nix imports modules/base/system-darwin.nix instead.
    (import ./../../modules/base/system-linux.nix { inherit isDesktop; })
    # NOTE: do NOT bake the flake's git revision into this system.
    #
    # An earlier revision of this file wrote `self.rev` to
    # /etc/nixos/configuration-revision from a `system.activationScripts`
    # entry. Activation scripts are part of `system.build.toplevel`, so the
    # 40-character commit SHA ended up inside every host's store path. That
    # made every commit to main change every host's closure hash, whether or
    # not the commit touched that host -- which destroyed the only signal
    # capable of answering "does this host actually need a deploy?".
    #
    # Deploy state is now derived by comparing the host's running closure
    # against the fleet manifest published by .github/workflows/fleet-manifest.yaml
    # (see modules/monitoring/agent/node_exporter.nix). The manifest maps each
    # host to the toplevel store path main currently expects, so the git
    # revision is recovered by reverse lookup instead of being baked in.
    # Reintroducing a rev-bearing activation script, `environment.etc` entry or
    # `system.configurationRevision` would silently break drift detection for
    # the whole fleet.
    hmInput.nixosModules.home-manager
    {
      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;

        users.${user} = {
          # shared HM baseline
          imports = [
            ./../../modules/base/home.nix
            # Linux-only half of home.nix (XDG, fonts, home directory); see
            # that file's own header. mk-darwin-system.nix does not add this.
            ./../../modules/base/home-linux.nix
            ./../../modules/services/attic/attic_client.nix
          ]
          ++ hmModules;
        };

        extraSpecialArgs = {
          inherit
            inputs
            user
            verbose_name
            hmlib
            github_email
            catppuccinInput
            nixYaziPluginsInput
            isDarwin
            ;
          stateVersion = checkedStateVersion;
        };
      };
    }
  ]
  ++ extraModules;
in
pkgsInput.lib.nixosSystem {
  specialArgs = _specialArgs;
  modules = _modules;
}
# Attach raw modules + args so the `colmena` output can reuse them
# without duplicating the entire module list.
// {
  _colmena = {
    nixpkgs = pkgsInput;
    specialArgs = _specialArgs;
    modules = _modules;
  };
}
