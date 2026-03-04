{
  description = "Fred's NixOS config flake";

  inputs = {
    nixpkgs = {
      url = "github:nixos/nixpkgs/nixos-unstable";
    };

    nixpkgs-stable = {
      url = "github:nixos/nixpkgs/nixos-25.11";
    };

    home-manager-stable = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    catppuccin = {
      url = "github:catppuccin/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    catppuccin-stable = {
      url = "github:catppuccin/nix/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs-stable";
    };

    apple-fonts = {
      url = "github:Lyndeno/apple-fonts.nix";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils = {
      url = "github:numtide/flake-utils";
    };

    nixvim = {
      url = "github:nix-community/nixvim";
    };

    niri = {
      url = "github:sodiboo/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    darwin = {
      url = "github:lnl7/nix-darwin";
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

    nixos-needsreboot = {
      url = "github:fredclausen/nixos-needsreboot";
    };

    precommit-base = {
      url = "github:FredSystems/pre-commit-checks";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    fredbar = {
      url = "github:FredSystems/fred-bar";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    solaar = {
      url = "github:Svenum/Solaar-Flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    colmena = {
      url = "github:zhaofengli/colmena";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # wallpapers

    walls-catppuccin = {
      url = "github:orangci/walls-catppuccin-mocha";
      flake = false;
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      nixpkgs-stable,
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
      solaar,
      colmena,
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
          forAllSystems
          # Channel inputs used as defaults for server nodes
          nixpkgs-stable
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
        desktop-common = import ./profiles/desktop-common.nix;
        adsb-hub = import ./profiles/adsb-hub.nix;

        # Hardware profiles (as a bundle)
        hardware-profiles = import ./hardware-profiles;

        # Individual hardware modules
        hardware-i2c = import ./hardware-profiles/i2c.nix;
        hardware-graphics = import ./hardware-profiles/graphics.nix;
        hardware-fingerprint = import ./hardware-profiles/fingerprint.nix;
        hardware-u2f = import ./hardware-profiles/u2f.nix;
        hardware-rtl-sdr = import ./hardware-profiles/rtl-sdr.nix;
        hardware-logitech = import ./hardware-profiles/logitech.nix;

        # Shared modules
        nas-mounts = import ./modules/data/nas-mounts.nix;
        wifi-networks = import ./modules/data/wifi-networks.nix;
        sync-hosts = import ./modules/data/sync-hosts.nix;

        # Service modules
        github-runners = import ./modules/github-runners.nix;

        # Default: all common modules
        default = {
          imports = [
            ./profiles/desktop-common.nix
            ./profiles/adsb-hub.nix
            ./hardware-profiles
            ./modules/data/nas-mounts.nix
            ./modules/data/wifi-networks.nix
            ./modules/data/sync-hosts.nix
            ./modules/github-runners.nix
          ];
        };
      };

      homeModules = {
        home-desktop = import ./profiles/home-desktop.nix;
        default = import ./profiles/home-desktop.nix;
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
