{
  description = "Fred's NixOS config flake";

  inputs = {
    nixpkgs = {
      url = "github:nixos/nixpkgs/nixos-unstable";
    };

    catppuccin = {
      url = "github:catppuccin/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    apple-fonts = {
      url = "github:Lyndeno/apple-fonts.nix";
      #url = "github:fredclausen/apple-fonts.nix";
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
      #inputs.nixpkgs.follows = "nixpkgs";
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

    nixos-needsreboot = {
      url = "github:fredclausen/nixos-needsreboot";
    };

    precommit-base = {
      url = "github:FredSystems/pre-commit-checks";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    fredbar = {
      #url = "path:/home/fred/GitHub/fred-bar";
      url = "github:FredSystems/fred-bar";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    solaar = {
      url = "https://flakehub.com/f/Svenum/Solaar-Flake/*.tar.gz"; # For latest stable version
      #url = "https://flakehub.com/f/Svenum/Solaar-Flake/0.1.7.tar.gz"; # uncomment line for solaar version 1.1.19
      #url = "github:Svenum/Solaar-Flake/main"; # Uncomment line for latest unstable version
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # wallpapers

    walls-catppuccin = {
      url = "github:orangci/walls-catppuccin-mocha";
      flake = false;
    };

    # attic = {
    #   url = "github:zhaofengli/attic";
    # };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      home-manager,
      catppuccin,
      apple-fonts,
      precommit-base,
      nixvim,
      niri,
      darwin,
      walls-catppuccin,
      solaar,
      #attic,
      ...
    }:

    let
      # centralize username in one place
      user = "fred";
      verbose_name = "Fred Clausen";
      github_email = "43556888+fredclausen@users.noreply.github.com";
      github_signing_key = "~/.ssh/id_ed25519_sk.pub";
      hmlib = home-manager.lib;

      agentNodes = builtins.filter (
        name: self.nixosConfigurations.${name}.config.deployment.role == "monitoring-agent"
      ) (builtins.attrNames self.nixosConfigurations);

      # Turn each node name into actual DNS/IP scrape targets
      agentTargets = map (name: "${name}.local") agentNodes;

      supportedSystems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          catppuccin-wallpapers = pkgs.stdenvNoCC.mkDerivation {
            pname = "catppuccin-wallpapers";
            version = "git";

            src = walls-catppuccin;

            installPhase = ''
              mkdir -p $out/share/backgrounds
              cp -r . $out/share/backgrounds/
            '';
          };
        }
      );

      ##########################################################################
      ## Exported Modules (for use in other flakes)                          ##
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
        nas-mounts = import ./shared/nas-mounts.nix;
        wifi-networks = import ./shared/wifi-networks.nix;
        sync-hosts = import ./shared/sync-hosts.nix;

        # Service modules
        github-runners = import ./modules/github-runners.nix;

        # Default: all common modules
        default = {
          imports = [
            ./profiles/desktop-common.nix
            ./profiles/adsb-hub.nix
            ./hardware-profiles
            ./shared/nas-mounts.nix
            ./shared/wifi-networks.nix
            ./shared/sync-hosts.nix
            ./modules/github-runners.nix
          ];
        };
      };

      homeModules = {
        # Home-manager desktop profile
        home-desktop = import ./profiles/home-desktop.nix;

        # Default
        default = import ./profiles/home-desktop.nix;
      };

      lib.mkSystem =
        {
          hostName,
          hmModules ? [ ],
          extraModules ? [ ],
          stateVersion ? "24.11",
          system ? "x86_64-linux",
        }:
        nixpkgs.lib.nixosSystem {
          specialArgs = {
            inherit
              inputs
              user
              verbose_name
              github_email
              github_signing_key
              hmlib
              system
              stateVersion
              agentNodes
              agentTargets
              ;

            catppuccinWallpapers = self.packages.${system}.catppuccin-wallpapers;
          };

          modules = [
            ./modules/deployment-meta.nix
            ./systems-linux/${hostName}/configuration.nix
            ./modules/common/system.nix
            home-manager.nixosModules.home-manager
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;

                users.${user} = {
                  # shared HM baseline
                  imports = [
                    ./modules/common/home.nix
                    ./modules/attic/attic_client.nix
                  ]
                  ++ hmModules;
                };

                extraSpecialArgs = {
                  inherit
                    inputs
                    self
                    user
                    verbose_name
                    hmlib
                    github_email
                    github_signing_key
                    catppuccin
                    apple-fonts
                    nixvim
                    niri
                    stateVersion
                    system
                    ;
                };
              };
            }
          ]
          ++ extraModules;
        };

      lib.mkDarwinSystem =
        {
          hostName,
          hmModules ? [ ],
          extraModules ? [ ],
          stateVersion ? "25.05",
          system ? "aarch64-darwin",
        }:
        darwin.lib.darwinSystem {
          specialArgs = {
            inherit
              inputs
              system
              user
              verbose_name
              github_email
              github_signing_key
              hmlib
              stateVersion
              ;
          };

          modules = [
            ./modules/deployment-meta.nix
            ./modules/common/system.nix
            ./systems-darwin/${hostName}/configuration.nix
            home-manager.darwinModules.home-manager

            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;

                users.${user} = {
                  imports = [ ./modules/common/home.nix ] ++ hmModules;

                  catppuccin = {
                    enable = true;
                    flavor = "mocha";
                    accent = "lavender";
                  };
                };

                extraSpecialArgs = {
                  inherit
                    inputs
                    self
                    system
                    user
                    verbose_name
                    hmlib
                    github_email
                    github_signing_key
                    catppuccin
                    nixvim
                    stateVersion
                    ;
                };
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
        };

      ##########################################################################
      ## System Definitions                                                  ##
      ##########################################################################

      nixosConfigurations = {
        Daytona = self.lib.mkSystem {
          hostName = "daytona";
          hmModules = [
            ./systems-linux/daytona/home.nix
          ];
          extraModules = [
            solaar.nixosModules.default
          ];
        };

        maranello = self.lib.mkSystem {
          hostName = "maranello";
          hmModules = [ ./systems-linux/maranello/home.nix ];
          extraModules = [
            solaar.nixosModules.default
          ];
        };

        sdrhub = self.lib.mkSystem {
          hostName = "sdrhub";
          hmModules = [ ];
        };

        fredhub = self.lib.mkSystem {
          hostName = "fredhub";
          stateVersion = "25.11";
          hmModules = [ ];
          #extraModules = [ attic.nixosModules.atticd ];
        };

        acarshub = self.lib.mkSystem {
          hostName = "acarshub";
          hmModules = [ ];
        };

        vdlmhub = self.lib.mkSystem {
          hostName = "vdlmhub";
          hmModules = [ ];
        };

        hfdlhub1 = self.lib.mkSystem {
          hostName = "hfdlhub1";
          hmModules = [ ];
        };

        hfdlhub2 = self.lib.mkSystem {
          hostName = "hfdlhub2";
          hmModules = [ ];
        };
      };

      # https://github.com/NixOS/nix-installer
      # sudo -i nix upgrade-nix
      darwinConfigurations = {
        "Freds-MacBook-Pro" = self.lib.mkDarwinSystem {
          hostName = "Freds-MacBook-Pro";
          hmModules = [ ./systems-darwin/Freds-MacBook-Pro/home.nix ];
        };

        "Freds-Mac-Studio" = self.lib.mkDarwinSystem {
          hostName = "Freds-Mac-Studio";
          hmModules = [ ./systems-darwin/Freds-MacBook-Pro/home.nix ];
        };
      };

      ##########################################################################
      ## Pre-commit checks (per system)                                       ##
      ##########################################################################

      checks = forAllSystems (system: {
        pre-commit-check = precommit-base.lib.mkCheck {
          inherit system;

          src = ./.;

          extraExcludes = [
            "secrets.yaml"
            "tsconfig.json"
          ];
        };
      });

      ##########################################################################
      ## Dev shells (per system, Rust-free)                                   ##
      ##########################################################################
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          inherit (self.checks.${system}.pre-commit-check) shellHook enabledPackages;
        in
        {
          default = pkgs.mkShell {
            # Bring in the hook packages + extra tools
            buildInputs =
              enabledPackages
              ++ (with pkgs; [
                nodejs
                nodePackages.typescript
              ]);

            shellHook = ''
              # Run git-hooks.nix setup (creates .pre-commit-config.yaml)
              ${shellHook}
            '';
          };
        }
      );
    };
}
