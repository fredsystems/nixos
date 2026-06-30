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
    ##########################################################################
    ## CI categories  (see agents.md for the full mapping)                  ##
    ##                                                                      ##
    ##   desktop + fredhub  — rebuilds desktops + fredhub                   ##
    ##   desktop            — rebuilds desktops only                        ##
    ##   server             — rebuilds servers only                         ##
    ##   global             — rebuilds all linux hosts                      ##
    ##   skip               — no linux rebuild needed                       ##
    ##########################################################################

    # CI: desktop + fredhub
    nixpkgs = {
      url = "github:nixos/nixpkgs/nixos-unstable";
    };

    # CI: server
    # renovate: datasource=git-refs depName=nixpkgs-stable packageName=https://github.com/NixOS/nixpkgs versioning=regex:^nixos-(?<major>\d+)\.(?<minor>\d+)$
    nixpkgs-stable = {
      url = "github:nixos/nixpkgs/nixos-26.05";
    };

    # CI: server
    #
    # Pinned-kernel input.  Tracks the `-small` variant of the same
    # stable channel as nixpkgs-stable but lives as its own flake input
    # so the kernel can be bumped on its own cadence (monthly,
    # manual-merge PR via .github/workflows/update-flakes.yaml) instead
    # of riding the weekly auto-merged stable bump.  Servers consume
    # linuxPackages_6_18 from this input via
    # modules/system/kernel-pin.nix.
    #
    # NOT tracked by Renovate: no `# renovate:` annotation, so the
    # custom regex manager in .github/renovate.json5 ignores it.  The
    # monthly update-flakes job advances flake.lock for this input via
    # `nix flake lock --update-input`; the channel name itself is bumped
    # by hand at NixOS release time.
    nixpkgs-kernel = {
      url = "github:nixos/nixpkgs/nixos-25.11-small";
    };

    # CI: server
    # renovate: datasource=git-refs depName=home-manager-stable packageName=https://github.com/nix-community/home-manager versioning=regex:^release-(?<major>\d+)\.(?<minor>\d+)$
    home-manager-stable = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    # CI: desktop
    # NOTE: deliberately NOT following our nixpkgs. catppuccin publishes
    # prebuilt outputs (whiskers, ports) to catppuccin.cachix.org built
    # against its own pinned nixpkgs. Following our nixpkgs would change
    # every derivation hash and force local rebuilds (cache miss). Keeping
    # catppuccin's own nixpkgs lets us substitute from its cache.
    catppuccin = {
      url = "github:catppuccin/nix";
    };

    # CI: server
    # renovate: datasource=git-refs depName=catppuccin-stable packageName=https://github.com/catppuccin/nix versioning=regex:^release-(?<major>\d+)\.(?<minor>\d+)$
    catppuccin-stable = {
      url = "github:catppuccin/nix/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    # CI: desktop
    apple-fonts = {
      url = "github:Lyndeno/apple-fonts.nix";
    };

    # CI: desktop
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # CI: skip (utility lib, no system builds)
    flake-utils = {
      url = "github:numtide/flake-utils";
    };

    # CI: global
    nixvim = {
      url = "github:nix-community/nixvim";
    };

    # CI: desktop
    # NOTE: deliberately NOT following our nixpkgs so niri's prebuilt
    # outputs can be substituted from niri.cachix.org / niri-epireyn.cachix.org
    # (built against niri's own pinned nixpkgs). Following our nixpkgs would
    # change the derivation hashes and force a local source build.
    niri = {
      # TODO: Watch both of these url's. sodiboo is the OG, but hasn't been updated in a while
      #url = "github:sodiboo/niri-flake";
      url = "github:epireyn/niri-flake";
    };

    # CI: skip (macOS only)
    darwin = {
      url = "github:nix-darwin/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # CI: desktop
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # CI: server
    sops-nix-stable = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    # CI: global (all linux)
    nixos-needsreboot = {
      url = "github:fredclausen/nixos-needsreboot";
    };

    # CI: skip (dev tooling only)
    precommit-base = {
      url = "github:FredSystems/pre-commit-checks";
    };

    # CI: desktop
    solaar = {
      url = "github:Svenum/Solaar-Flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # CI: skip (deployment tool, no effect on builds)
    # NOTE: deliberately NOT following our nixpkgs so the colmena CLI binary
    # can be substituted from colmena.cachix.org (built against colmena's own
    # pinned nixpkgs). Following our nixpkgs would change its derivation hash
    # and force a local source build of the whole Rust closure.
    colmena = {
      url = "github:zhaofengli/colmena";
    };

    # CI: desktop
    freminal = {
      url = "github:FredSystems/freminal";
      #path on disk
      #url = "git+file:/home/fred/GitHub/freminal";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # CI: desktop
    frext = {
      url = "github:FredSystems/frext";
      #path on disk
      #url = "git+file:/home/fred/GitHub/frext";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # wallpapers

    # CI: desktop
    walls-catppuccin = {
      url = "github:orangci/walls-catppuccin-mocha";
      flake = false;
    };

    # CI: desktop
    # Community-maintained mirror of the (taken-down) catppuccin/wallpapers
    # repo. Provides the original 11 categories (dithered, flatppuccin,
    # gradients, landscapes, mandelbrot, minimalistic, misc, os, patterns,
    # solids, waves).
    walls-zhichaoh = {
      url = "github:zhichaoh/catppuccin-wallpapers";
      flake = false;
    };

    # CI: desktop
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
      apple-fonts,
      nixvim,
      niri,
      darwin,
      walls-catppuccin,
      walls-zhichaoh,
      walls-cozypixels,
      solaar,
      colmena,
      freminal,
      frext,
      ...
    }:

    let
      ##########################################################################
      ## Identity                                                             ##
      ##########################################################################

      user = "fred";
      verbose_name = "Fred Clausen";
      github_email = "43556888+fredclausen@users.noreply.github.com";
      github_signing_key = "~/.ssh/id_ed25519_sk.pub";
      hmlib = home-manager.lib;

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

      agentTargets = map (name: "${name}.local") agentNodes;

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
          github_signing_key
          hmlib
          serverNodes
          agentNodes
          agentTargets
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
          # Flake inputs required by lib functions / modules
          nixpkgs
          home-manager
          catppuccin
          darwin
          nixvim
          niri
          apple-fonts
          solaar
          colmena
          walls-catppuccin
          walls-zhichaoh
          walls-cozypixels
          freminal
          frext
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
      };

      ##########################################################################
      ## Exported modules (for use in other flakes)                          ##
      ##########################################################################

      nixosModules = {
        # Profiles
        desktop-common = import ./profiles/desktop.nix;
        adsb-hub = import ./profiles/adsb-hub.nix;

        # Hardware profiles (as a bundle)
        hardware-profiles = import ./modules/hardware;

        # Individual hardware modules
        hardware-i2c = import ./modules/hardware/i2c.nix;
        hardware-graphics = import ./modules/hardware/graphics.nix;
        hardware-fingerprint = import ./modules/hardware/fingerprint.nix;
        hardware-u2f = import ./modules/hardware/u2f.nix;
        hardware-rtl-sdr = import ./modules/hardware/rtl-sdr.nix;
        hardware-logitech = import ./modules/hardware/logitech.nix;

        # Shared modules
        nas-mounts = import ./modules/data/nas-mounts.nix;
        wifi-networks = import ./modules/data/wifi-networks.nix;
        sync-hosts = import ./modules/data/sync-hosts.nix;

        # Service modules
        github-runners = import ./modules/services/github-runners.nix;

        # Default: all common modules
        default = {
          imports = [
            ./profiles/desktop.nix
            ./profiles/adsb-hub.nix
            ./modules/hardware
            ./modules/data/nas-mounts.nix
            ./modules/data/wifi-networks.nix
            ./modules/data/sync-hosts.nix
            ./modules/services/github-runners.nix
          ];
        };
      };

      homeModules = {
        home-desktop = import ./home-profiles/desktop.nix;
        default = import ./home-profiles/desktop.nix;
      };

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
