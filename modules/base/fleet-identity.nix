{ lib, ... }:
{
  # Fleet-wide identity and topology data, as options rather than builder
  # arguments.
  #
  # These replace specialArgs the three construction paths (mkSystem,
  # mkDarwinSystem, Colmena) used to pass by hand, so that modules -- and,
  # eventually, the exported `nixosModules` / `homeModules` -- can read fleet
  # data from `config` instead of needing a builder argument threaded all the
  # way down to them. `flake/lib/mk-system.nix` and
  # `flake/lib/mk-darwin-system.nix` set these from the values they already
  # have. See agent-docs/plans/PLAN_04_MODULE_INTERFACES.md.
  #
  # `shared` is already used as a namespace by other modules (see
  # modules/data/*.nix, e.g. `shared.nasMounts`, `shared.homePublicIPv4`);
  # these are additional sub-options under the same namespace.
  options.shared = {
    user = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Login name of the fleet's primary user (previously the `user` specialArg).";
      };

      fullName = lib.mkOption {
        type = lib.types.str;
        description = "Display name of the fleet's primary user (previously the `verbose_name` specialArg).";
      };

      email = lib.mkOption {
        type = lib.types.str;
        description = "Email address of the fleet's primary user (previously the `github_email` specialArg).";
      };
    };

    extraUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional login users that get the same per-user configuration as the primary user (previously the `extraUsers` specialArg).";
    };

    monitoring = {
      agentNodes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Host names whose `deployment.role` is \"monitoring-agent\".";
      };

      agentScrapeMap = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Monitoring-agent host name -> address Prometheus scrapes.";
      };

      desktopNodes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Desktop host names participating in the monitoring topology.";
      };

      desktopScrapeMap = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Desktop host name -> address Prometheus scrapes.";
      };
    };

    catppuccinWallpapers = lib.mkOption {
      type = lib.types.package;
      description = ''
        The catppuccin wallpaper package installed on Linux desktops. Set by
        flake/lib/mk-system.nix only; nix-darwin hosts never set it, and
        nothing they import reads it (only features/desktop/environments,
        which Darwin does not import). It deliberately has no default, so a
        Darwin module that starts reading it fails evaluation loudly instead
        of silently getting a placeholder.
      '';
    };
  };
}
