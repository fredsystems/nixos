{
  lib,
  pkgs,
  config,
  user,
  extraUsers ? [ ],
  system,
  ...
}:
with lib;
let
  cfg = config.desktop.yubikey;
  allUsers = [ user ] ++ extraUsers;
  isDarwin = lib.hasSuffix "darwin" system;
  isLinux = !isDarwin;
in
{
  options.desktop.yubikey = {
    enable = mkOption {
      description = "Install Yubikey Manager.";
      default = false;
    };
  };

  imports = lib.optional isLinux ./linux.nix ++ lib.optional isDarwin ./mac.nix;

  config = mkIf cfg.enable {
    home-manager.users = lib.genAttrs allUsers (_: {
      services.yubikey-agent.enable = true;

      programs.gpg = {
        enable = true;
        settings = {
          "no-tty" = true;
        };

        scdaemonSettings = {
          disable-ccid = true;
        };
      };
    });

    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        yubikey-manager
        pam_u2f
        yubioath-flutter
        yubico-piv-tool
      ];
    });
  };
}
