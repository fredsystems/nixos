{
  description = "Fred's NixOS config flake";

  # Extra binary caches for inputs that are deliberately NOT following our
  # nixpkgs (colmena, catppuccin, niri). Their upstream CI publishes prebuilt
  # outputs to these caches built against each project's own pinned nixpkgs,
  # so substitution only works when we keep those inputs' nixpkgs unchanged.
  # `extra-*` appends to (does not replace) the system / CI substituters.
  nixConfig = {
    extra-substituters = [
      "https://colmena.cachix.org"
      "https://catppuccin.cachix.org"
      "https://niri.cachix.org"
      "https://niri-epireyn.cachix.org"
    ];
    extra-trusted-public-keys = [
      "colmena.cachix.org-1:7BzpDnjjH8ki2CT3f6GdOk7QAzPOl+1t3LvTLXqYcSg="
      "catppuccin.cachix.org-1:noG/4HkbhJb+lUAdKrph6LaozJvAeEEZj4N732IysmU="
      "niri.cachix.org-1:Wv0OmO7PsuocRKzfDoJ3mulSl7Z6oezYhGhR+3W2964="
      "niri-epireyn.cachix.org-1:tlVyFN7CtsDT+ZcLPS+ekFWeT1X6X4OqvWqbBMyIzFA="
    ];
  };

  inputs = {
    nixpkgs = {
      url = "github:nixos/nixpkgs/nixos-unstable";
    };

    # renovate: datasource=git-refs depName=nixpkgs-stable packageName=https://github.com/NixOS/nixpkgs versioning=regex:^nixos-(?<major>\d+)\.(?<minor>\d+)$
    nixpkgs-stable = {
      url = "github:nixos/nixpkgs/nixos-26.05";
    };

    # Pinned-kernel input.  Tracks the `-small` variant of the same
    # stable channel as nixpkgs-stable but lives as its own flake input
    # so the kernel can be bumped on its own cadence (monthly,
    # manual-merge PR via .github/workflows/update-flakes.yaml) instead
    # of riding the weekly auto-merged stable bump.  Servers consume
    # linuxPackages_6_18 from this input via
    # modules/system/kernel-pin.nix.
    #
    # Two separate cadences act on this input, and they do not overlap:
    #   * COMMITS within the channel -> flake.lock only, advanced by the
    #     monthly manual-merge job in update-flakes.yaml.  Renovate never
    #     touches flake.lock (lockFileMaintenance is deliberately off).
    #   * The CHANNEL NAME itself (e.g. nixos-25.11-small ->
    #     nixos-26.05-small) -> flake.nix, proposed by Renovate via the
    #     annotation below and grouped into the "nixos stable channel"
    #     PR so the release bump lands atomically with nixpkgs-stable.
    #
    # The versioning regex MUST keep the `-small` suffix: a channel ref
    # that does not match is treated by Renovate as an unparseable
    # currentValue and silently never updated.
    #
    # renovate: datasource=git-refs depName=nixpkgs-kernel packageName=https://github.com/NixOS/nixpkgs versioning=regex:^nixos-(?<major>\d+)\.(?<minor>\d+)-small$
    nixpkgs-kernel = {
      url = "github:nixos/nixpkgs/nixos-26.05-small";
    };

    # renovate: datasource=git-refs depName=home-manager-stable packageName=https://github.com/nix-community/home-manager versioning=regex:^release-(?<major>\d+)\.(?<minor>\d+)$
    home-manager-stable = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    # NOTE: deliberately NOT following our nixpkgs. catppuccin publishes
    # prebuilt outputs (whiskers, ports) to catppuccin.cachix.org built
    # against its own pinned nixpkgs. Following our nixpkgs would change
    # every derivation hash and force local rebuilds (cache miss). Keeping
    # catppuccin's own nixpkgs lets us substitute from its cache.
    catppuccin = {
      url = "github:catppuccin/nix";
    };

    # renovate: datasource=git-refs depName=catppuccin-stable packageName=https://github.com/catppuccin/nix versioning=regex:^release-(?<major>\d+)\.(?<minor>\d+)$
    catppuccin-stable = {
      url = "github:catppuccin/nix/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    nix-yazi-plugins = {
      url = "github:lordkekz/nix-yazi-plugins";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-yazi-plugins-stable = {
      url = "github:lordkekz/nix-yazi-plugins";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils = {
      url = "github:numtide/flake-utils";
    };

    # renovate: datasource=git-refs depName=nix-flatpak packageName=https://github.com/gmodena/nix-flatpak versioning=semver
    nix-flatpak = {
      url = "github:gmodena/nix-flatpak/v0.8.0"; # unstable branch. Use github:gmodena/nix-flatpak/<tag> to pin releases.
    };

    # Imported for its home-manager module ONLY -- the package comes from
    # nixpkgs on Linux and from the upstream .app bundle on Darwin (see
    # features/desktop/lan-mouse). That is why this follows our nixpkgs
    # despite upstream publishing to lan-mouse.cachix.org: we never build
    # their derivation, so there is nothing for that cache to serve, and
    # following avoids dragging a second nixpkgs into the closure.
    lan-mouse = {
      url = "github:feschber/lan-mouse";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # NOTE: deliberately NOT following our nixpkgs. nixvim builds neovim and
    # its plugins from its own pinned nixpkgs (features/shell/nvim/default.nix
    # sets nixvim's own nixpkgs.config, which forces that), so a host nixpkgs
    # bump cannot break the editor. Its pin is a Hydra-built nixpkgs-unstable
    # revision, so everything substitutes from cache.nixos.org.
    nixvim = {
      url = "github:nix-community/nixvim";
    };

    # NOTE: deliberately NOT following our nixpkgs so niri's prebuilt
    # outputs can be substituted from niri.cachix.org / niri-epireyn.cachix.org
    # (built against niri's own pinned nixpkgs). Following our nixpkgs would
    # change the derivation hashes and force a local source build.
    niri = {
      # TODO: Watch both of these url's. sodiboo is the OG, but hasn't been updated in a while
      #url = "github:sodiboo/niri-flake";
      url = "github:epireyn/niri-flake";
    };

    darwin = {
      url = "github:nix-darwin/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix-stable = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    # Consumed through its overlay so each host builds it against its own
    # nixpkgs (stable on servers, unstable on desktops). No public cache
    # serves it, so there is nothing to gain from its pinned nixpkgs, and
    # following ours keeps a second nixpkgs out of the lock.
    nixos-needsreboot = {
      url = "github:fredclausen/nixos-needsreboot";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # NOTE: deliberately NOT following our nixpkgs. It only feeds the dev
    # shell and the pre-commit / flake checks, never a host closure, and its
    # own pin keeps the lint toolchain from moving underneath a commit when
    # our nixpkgs is bumped.
    precommit-base = {
      url = "github:FredSystems/pre-commit-checks";
    };

    # NOTE: deliberately NOT following our nixpkgs so the colmena CLI binary
    # can be substituted from colmena.cachix.org (built against colmena's own
    # pinned nixpkgs). Following our nixpkgs would change its derivation hash
    # and force a local source build of the whole Rust closure.
    colmena = {
      url = "github:zhaofengli/colmena";
    };

    # OpenCode 2, built from upstream's own flake (nix/opencode.nix). Pinned
    # to a release tag: v2 releases are tags, `dev` is not a release.
    #
    # NOTE: deliberately NOT following our nixpkgs. Upstream keeps the
    # node_modules fixed-output hash per release in nix/hashes.json, and that
    # hash is only valid for the bun in upstream's pinned nixpkgs. Following
    # ours would let a bun bump invalidate it, which is exactly the
    # hash-maintenance loop the old overlays/opencode.nix needed a daily
    # workflow for.
    #
    # Upstream does not always merge its hash bump before tagging, though, so
    # renovate-relock.yaml verifies the hash on every opencode bump and
    # flake/lib/opencode-overlay.nix applies a corrected one when it is stale.
    # renovate: datasource=git-refs depName=opencode packageName=https://github.com/anomalyco/opencode versioning=semver
    opencode = {
      url = "github:anomalyco/opencode/v2.2.7";
    };

    freminal = {
      url = "github:FredSystems/freminal";
      #path on disk
      #url = "git+file:/home/fred/GitHub/freminal";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    frext = {
      url = "github:FredSystems/frext";
      #path on disk
      #url = "git+file:/home/fred/GitHub/frext";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Only sdrhub runs this (monitoring master), and sdrhub is a server, so a
    # bump rebuilds the server set rather than the desktops.
    github-ci-exporter = {
      url = "github:FredSystems/github-ci-exporter";
      #path on disk
      #url = "git+file:/home/fred/GitHub/github-ci-exporter";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # ADS-B receiver comparison recorder (plan 02). Only sdrhub runs it, and
    # sdrhub is a stable-channel server, so it follows nixpkgs-stable.
    beast-compare = {
      url = "github:fredsystems/beast-compare";
      #path on disk
      #url = "git+file:/home/fred/GitHub/beast-compare";
      inputs = {
        nixpkgs.follows = "nixpkgs-stable";
        flake-utils.follows = "flake-utils";
        precommit-base.follows = "precommit-base";
      };
    };

    # wallpapers

    walls-catppuccin = {
      url = "github:orangci/walls-catppuccin-mocha";
      flake = false;
    };

    # Community-maintained mirror of the (taken-down) catppuccin/wallpapers
    # repo. Provides the original 11 categories (dithered, flatppuccin,
    # gradients, landscapes, mandelbrot, minimalistic, misc, os, patterns,
    # solids, waves).
    walls-zhichaoh = {
      url = "github:zhichaoh/catppuccin-wallpapers";
      flake = false;
    };

    # Curated cozy/aesthetic collection. We only consume the Catppuccin/
    # subtree from this repo (it also ships Nord and One Dark variants).
    walls-cozypixels = {
      url = "github:SleepyCatHey/CozyPixels";
      flake = false;
    };

    # NOTE: daylinmorgan/catppuccin-wallpapers is NOT a flake input.
    # It is fetched as a release tarball via pkgs.fetchurl inside
    # flake/dev/packages.nix because:
    #   1. The upstream repo ships only SVG sources + a Python+Inkscape
    #      generator — generating PNGs at build time would pull a ~500MB
    #      Inkscape closure for only 4 base designs.
    #   2. The pre-generated PNGs are released as .tar.gz on the v2022.05.02
    #      release.  The repo has been dormant since 2022, so a pinned
    #      release tarball is fully equivalent to (and cheaper than)
    #      tracking the git source.
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      nixpkgs-stable,
      nixpkgs-kernel,
      home-manager,
      home-manager-stable,
      catppuccin,
      catppuccin-stable,
      sops-nix-stable,
      nixvim,
      nix-flatpak,
      niri,
      darwin,
      walls-catppuccin,
      walls-zhichaoh,
      walls-cozypixels,
      colmena,
      freminal,
      frext,
      nix-yazi-plugins,
      nix-yazi-plugins-stable,
      ...
    }:

    let
      ##########################################################################
      ## Identity                                                             ##
      ##########################################################################

      user = "fred";
      verbose_name = "Fred Clausen";
      github_email = "43556888+fredclausen@users.noreply.github.com";

      ##########################################################################
      ## Supported systems                                                    ##
      ##########################################################################

      supportedSystems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      ##########################################################################
      ## Server node table                                                    ##
      ##                                                                      ##
      ## Edit flake/hosts/servers.nix to add / change server machines.       ##
      ##########################################################################

      serverNodes = import ./flake/hosts/servers.nix;

      ##########################################################################
      ## Monitoring topology                                                  ##
      ##                                                                      ##
      ## Derived lazily from nixosConfigurations — resolved via the self      ##
      ## fixed-point so the ordering of outputs does not matter.             ##
      ##########################################################################

      agentNodes = builtins.filter (
        name: self.nixosConfigurations.${name}.config.deployment.role == "monitoring-agent"
      ) (builtins.attrNames self.nixosConfigurations);

      agentScrapeMap = builtins.listToAttrs (
        map (name: {
          inherit name;
          value =
            let
              addr = self.nixosConfigurations.${name}.config.deployment.scrapeAddress;
            in
            if addr != null then addr else "${name}.local";
        }) agentNodes
      );

      desktopNodes = builtins.filter (
        name: self.nixosConfigurations.${name}.config.deployment.role == "desktop"
      ) (builtins.attrNames self.nixosConfigurations);

      desktopScrapeMap = builtins.listToAttrs (
        map (name: {
          inherit name;
          value =
            let
              addr = self.nixosConfigurations.${name}.config.deployment.scrapeAddress;
            in
            if addr != null then addr else "${name}.local";
        }) desktopNodes
      );

      ##########################################################################
      ## Shared arguments                                                     ##
      ##                                                                      ##
      ## Passed into every flake/* importer.  Files destructure what they    ##
      ## need and ignore the rest via `...`.                                  ##
      ##########################################################################

      sharedArgs = {
        inherit
          inputs
          self
          user
          verbose_name
          github_email
          serverNodes
          agentNodes
          agentScrapeMap
          desktopNodes
          desktopScrapeMap
          forAllSystems
          # Channel inputs used as defaults for server nodes
          nixpkgs-stable
          nixpkgs-kernel
          home-manager-stable
          catppuccin-stable
          sops-nix-stable
          nix-yazi-plugins-stable
          # Flake inputs required by lib functions / modules
          nixpkgs
          home-manager
          catppuccin
          nix-yazi-plugins
          darwin
          nixvim
          niri
          colmena
          walls-catppuccin
          walls-zhichaoh
          walls-cozypixels
          freminal
          frext
          nix-flatpak
          ;
      };
    in
    {
      ##########################################################################
      ## Library functions                                                    ##
      ##########################################################################

      lib = {
        # Build a NixOS system.  Also exposes _colmena so the colmena output
        # can reuse the same modules without duplication.
        mkSystem = import ./flake/lib/mk-system.nix sharedArgs;

        # Build a nix-darwin system.
        mkDarwinSystem = import ./flake/lib/mk-darwin-system.nix sharedArgs;

        # What the deploy guards (scripts/lib/deploy-guard.sh) compare a
        # running node against. One function, evaluated over both node sets,
        # so the desktop preflight and the colmena wrapper cannot disagree on
        # what a target looks like. See flake/lib/deploy-facts.nix.
        deployFacts =
          let
            facts = import ./flake/lib/deploy-facts.nix { inherit (nixpkgs) lib; };
          in
          {
            inherit (facts) of;
            nixos = facts.forNodes self.nixosConfigurations;
            colmena = facts.forNodes self.colmenaHive.nodes;
          };
      };

      ##########################################################################
      ## Exported modules (for use in other flakes)                          ##
      ##########################################################################

      # See flake/exports.nix: bare exports of this repository's modules, plus
      # `dependencies` for consumers that do not bring their own copies of
      # the third-party modules.
      inherit (import ./flake/exports.nix { inherit inputs; }) nixosModules homeModules;

      ##########################################################################
      ## System configurations                                                ##
      ##########################################################################

      nixosConfigurations = import ./flake/hosts/nixos.nix sharedArgs;

      darwinConfigurations = import ./flake/hosts/darwin.nix sharedArgs;
    }

    ##########################################################################
    ## Deployment, packages, checks, dev shell                              ##
    ## Each file returns an attrset that is merged into the outputs.        ##
    ##########################################################################

    // import ./flake/deployment/colmena.nix sharedArgs
    // import ./flake/dev/packages.nix sharedArgs
    // import ./flake/dev/checks.nix sharedArgs
    // import ./flake/dev/shell.nix sharedArgs;
}
