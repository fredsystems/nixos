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
      #url = "path:/home/fred/GitHub/fred-bar";
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
      precommit-base,
      nixvim,
      niri,
      darwin,
      walls-catppuccin,
      solaar,
      colmena,
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

      # Map of hostname -> scrape address for Prometheus.
      # Uses deployment.scrapeAddress when set (e.g. a Tailscale MagicDNS name),
      # otherwise falls back to <hostname>.local for LAN nodes.
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

      supportedSystems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      ##########################################################################
      ## Server node definitions — single source of truth                    ##
      ##                                                                      ##
      ## Drives BOTH nixosConfigurations and the colmena topology.           ##
      ## stateVersion, extraUsers, channel inputs, and deployment metadata   ##
      ## all live here — one edit propagates everywhere.                     ##
      ##                                                                      ##
      ## To add a server:                                                     ##
      ##   1. Create systems-linux/<name>/configuration.nix                  ##
      ##   2. Add one entry below — everything else is derived.              ##
      ##                                                                      ##
      ## Per-entry fields (all optional — defaults shown):                   ##
      ##   stateVersion         = "24.11"                                    ##
      ##   extraUsers           = []                                         ##
      ##   hmModules            = []                                         ##
      ##   extraModules         = []                                         ##
      ##   pkgsInput            = nixpkgs-stable                             ##
      ##   hmInput              = home-manager-stable                        ##
      ##   catppuccinInput      = catppuccin-stable                          ##
      ##   sopsNixInput         = sops-nix-stable                            ##
      ##   targetHost           = "<name>.local"  (colmena SSH target)       ##
      ##   tags                 = []              (colmena node-specific tags)##
      ##   allowLocalDeployment = false           (colmena)                  ##
      ##########################################################################
      serverNodes = {
        fredhub = {
          stateVersion = "25.11";
          tags = [ "hub" ];
          allowLocalDeployment = true;
        };
        fredvps = {
          stateVersion = "25.05";
          extraUsers = [ "nik" ];
          extraModules = [
            {
              home-manager.users.nik = {
                imports = [
                  ./systems-linux/fredvps/nik-home.nix
                ];
              };
            }
          ];
          targetHost = "fredclausen.com";
          targetPort = 2269;
          tags = [ "vps" ];
        };
        sdrhub = {
          tags = [ "sdr" ];
        };
        acarshub = {
          tags = [ "adsb" ];
        };
        vdlmhub = {
          tags = [ "adsb" ];
        };
        hfdlhub1 = {
          tags = [ "hfdl" ];
        };
        hfdlhub2 = {
          tags = [ "hfdl" ];
        };
      };
    in
    {
      colmenaHive = colmena.lib.makeHive self.outputs.colmena;
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
          extraUsers ? [ ],
          # Override these four to put a host on a different nixpkgs channel.
          # Defaults to nixos-unstable + matching home-manager/catppuccin/sops-nix branches.
          pkgsInput ? nixpkgs,
          hmInput ? home-manager,
          catppuccinInput ? catppuccin,
          sopsNixInput ? inputs.sops-nix,
          # Set to true for desktop systems — gates the desktop package tree.
          # Desktop systems are always on unstable; servers may be on stable.
          isDesktop ? false,
        }:
        let
          _specialArgs = {
            inherit
              inputs
              user
              extraUsers
              verbose_name
              github_email
              github_signing_key
              hmlib
              system
              stateVersion
              agentNodes
              agentTargets
              agentScrapeMap
              isDesktop
              catppuccinInput
              sopsNixInput
              ;

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
              }
            )
            ./modules/deployment-meta.nix
            ./systems-linux/${hostName}/configuration.nix
            ./modules/common/system.nix

            hmInput.nixosModules.home-manager
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
                    catppuccinInput
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
        in
        pkgsInput.lib.nixosSystem {
          specialArgs = _specialArgs;
          modules = _modules;
        }
        # Attach raw modules + args so the `colmena` output below can reuse
        # them without duplicating the entire module list.
        // {
          _colmena = {
            nixpkgs = pkgsInput;
            specialArgs = _specialArgs;
            modules = _modules;
          };
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

      nixosConfigurations =
        # ── Desktop machines — unstable channel, not colmena-managed ──────────
        {
          Daytona = self.lib.mkSystem {
            hostName = "daytona";
            isDesktop = true;
            hmModules = [ ./systems-linux/daytona/home.nix ];
            extraModules = [ solaar.nixosModules.default ];
          };

          maranello = self.lib.mkSystem {
            hostName = "maranello";
            isDesktop = true;
            hmModules = [ ./systems-linux/maranello/home.nix ];
            extraModules = [ solaar.nixosModules.default ];
          };
        }
        # ── Server machines — derived from serverNodes above ──────────────────
        // builtins.mapAttrs (
          name: node:
          self.lib.mkSystem {
            hostName = name;
            stateVersion = node.stateVersion or "24.11";
            extraUsers = node.extraUsers or [ ];
            pkgsInput = node.pkgsInput or nixpkgs-stable;
            hmInput = node.hmInput or home-manager-stable;
            catppuccinInput = node.catppuccinInput or catppuccin-stable;
            sopsNixInput = node.sopsNixInput or sops-nix-stable;
            hmModules = node.hmModules or [ ];
            extraModules = node.extraModules or [ ];
          }
        ) serverNodes;

      ##########################################################################
      ## Colmena — server-only deployment topology                           ##
      ##                                                                      ##
      ## Desktop machines (Daytona, maranello) and Darwin machines are       ##
      ## intentionally excluded — manage those locally.                      ##
      ##                                                                      ##
      ## Usage:                                                               ##
      ##   colmena apply                        # deploy all servers          ##
      ##   colmena apply --on '@stable'         # deploy all stable servers   ##
      ##   colmena apply --on fredhub           # deploy one server           ##
      ##   colmena apply --on '@adsb'           # deploy by tag               ##
      ##   colmena build                        # dry-run / build only        ##
      ##########################################################################

      colmena =
        let
          # All deployment metadata is read from serverNodes (defined at the top
          # of the outer let block), which also drives nixosConfigurations.
          # stateVersion, extraUsers, channel inputs — one place to change them.
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
        in
        # Merge static meta block with the per-node attrset produced by mapAttrs.
        {
          meta = {
            # Fallback nixpkgs; individual nodes are pinned via nodeNixpkgs.
            # Shadow the deprecated `pkgs.system` alias (warnAlias since 2025-10-28)
            # so Colmena's `inherit (npkgs) system` in eval.nix doesn't fire the
            # "'system' has been renamed to/replaced by 'stdenv.hostPlatform.system'"
            # warning. Colmena always calls evalConfig { inherit (npkgs) system; ... }
            # which forces npkgs.system — overriding it with the non-alias value
            # pkgs.stdenv.hostPlatform.system avoids the lazy warn thunk entirely.
            nixpkgs =
              let
                pkgs = import nixpkgs { system = "x86_64-linux"; };
              in
              pkgs // { inherit (pkgs.stdenv.hostPlatform) system; };

            # Derived from each node's mkSystem pkgsInput — changing a node's
            # channel in nixosConfigurations automatically propagates here.
            # Same pkgs.system shadow as meta.nixpkgs above — see comment there.
            nodeNixpkgs = builtins.mapAttrs (
              name: _:
              let
                pkgs = import self.nixosConfigurations.${name}._colmena.nixpkgs { system = "x86_64-linux"; };
              in
              pkgs // { inherit (pkgs.stdenv.hostPlatform) system; }
            ) serverNodes;

            # Shared specialArgs passed to ALL nodes as true specialArgs
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
              # Defaults; overridden per-node in nodeSpecialArgs below.
              stateVersion = "24.11";
              extraUsers = [ ];
              catppuccinInput = catppuccin-stable;
              sopsNixInput = sops-nix-stable;
              catppuccinWallpapers = self.packages."x86_64-linux".catppuccin-wallpapers;
            };

            # Per-node overrides derived from the servers table.
            # Channel-sensitive args (catppuccinInput, sopsNixInput) are pulled
            # from _colmena.specialArgs so they stay in sync with mkSystem
            # automatically — no manual updates needed when changing channels.
            nodeSpecialArgs = builtins.mapAttrs (_: node: {
              stateVersion = node.stateVersion or "24.11";
              extraUsers = node.extraUsers or [ ];
              catppuccinInput = node.catppuccinInput or catppuccin-stable;
              sopsNixInput = node.sopsNixInput or sops-nix-stable;
            }) serverNodes;
          };
        }
        // builtins.mapAttrs mkNode serverNodes;

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
                # Colmena: multi-machine NixOS deployment tool.
                # Use the binary from the colmena flake input so the CLI version
                # matches the evaluator used by colmenaHive (not pkgs.colmena
                # from nixpkgs, which is shadowed by the flake input attrset).
                colmena.packages.${system}.colmena
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
