{
  lib,
  options,
  config,
  ...
}:

let
  verbose_name = config.shared.user.fullName;
  github_email = config.shared.user.email;

  yubikeyMap = {
    "13380413" = "~/.ssh/id_ed25519_sk.pub";
    "35681557" = "~/.ssh/id_ed25519_sk_github.pub";
  };

  yubikeyMapText = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (serial: key: "${serial} ${key}") yubikeyMap
  );
in
{
  ##########################################################################
  ## Shared Home-Manager module imports
  ##########################################################################
  # catppuccin's and nixvim's home-manager modules are wired by the builders
  # through home-manager.sharedModules (see ./home-catppuccin.nix).
  imports = [
    ../../modules/base/home-base.nix
  ];

  ##########################################################################
  ## catppuccin (home-manager)
  ##########################################################################
  # `autoEnable` was introduced in catppuccin/nix #817 (post-25.11). The
  # release-25.11 input used by server hosts does not have this option yet,
  # so guard the assignment on its presence. Setting it to `false` keeps
  # current behavior (per-port enables remain explicit in feature modules)
  # and suppresses the "catppuccin/nix will soon auto enroll ports" warning
  # at the home-manager profile level on hosts pinned to unstable.
  catppuccin = {
    enable = true;
    flavor = "mocha";
    accent = "mauve";

    # `sources` and the gemini-cli guard depend on which catppuccin input
    # this host uses; see ./home-catppuccin.nix.
  }
  // lib.optionalAttrs (options.catppuccin ? autoEnable) {
    autoEnable = true;
  };

  ##########################################################################
  ## .gitconfig — fully generated
  ##########################################################################
  home.file.".gitconfig".text = import ../../modules/lib/gitconfig-template.nix {
    name = verbose_name;
    email = github_email;
  };

  home.file.".config/git/yubikey-map" = {
    text = yubikeyMapText + "\n";
  };
}
