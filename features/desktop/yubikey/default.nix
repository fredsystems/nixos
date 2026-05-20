{
  lib,
  pkgs,
  config,
  user,
  extraUsers ? [ ],
  isDarwin,
  ...
}:
let
  cfg = config.desktop.yubikey;
  allUsers = [ user ] ++ extraUsers;
  isLinux = !isDarwin;
in
{
  options.desktop.yubikey = {
    enable = lib.mkEnableOption "Yubikey Manager";
  };

  imports = lib.optional isLinux ./linux.nix ++ lib.optional isDarwin ./mac.nix;

  config = lib.mkIf cfg.enable {
    home-manager.users = lib.genAttrs allUsers (_: {
      services.yubikey-agent.enable = true;

      # home-manager's yubikey-agent module sets sshAuthSock.initialization.fish
      # using bash parameter expansion syntax (${VAR:-default}) which fish cannot
      # parse. Override it with valid fish syntax.
      sshAuthSock.initialization.fish = lib.mkForce ''
        set -x SSH_AUTH_SOCK (if test -n "$XDG_RUNTIME_DIR"; echo $XDG_RUNTIME_DIR; else; echo /run/user/(id -u); end)/yubikey-agent/yubikey-agent.sock
      '';

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
