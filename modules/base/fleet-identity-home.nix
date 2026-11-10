{ config, lib, ... }:
{
  # Home Manager side of modules/base/fleet-identity.nix. Home Manager is a
  # separate module system -- it cannot see the system tree's `config.shared.*`
  # -- so it declares its own small set of options here, set by the bridge in
  # modules/base/fleet-identity-hm-bridge.nix. See
  # agent-docs/plans/PLAN_04_MODULE_INTERFACES.md.
  options.shared = {
    user = {
      name = lib.mkOption {
        type = lib.types.str;
        default = config.home.username;
        defaultText = lib.literalExpression "config.home.username";
        description = ''
          The fleet's PRIMARY user (the same for every Home Manager user on a
          host, matching the old `user` argument); use `home.username` for the
          user this configuration belongs to.
        '';
      };

      fullName = lib.mkOption {
        type = lib.types.str;
        description = "Display name of the fleet's primary user.";
      };

      email = lib.mkOption {
        type = lib.types.str;
        description = "Email address of the fleet's primary user.";
      };
    };

    hostSystem = lib.mkOption {
      type = lib.types.str;
      description = ''
        The host's platform string (e.g. "x86_64-linux"), copied from the
        system's `nixpkgs.hostPlatform.system`; exists so Home Manager modules
        can name the platform without forcing `pkgs` (see
        features/shell/nvim/default.nix).
      '';
    };
  };
}
