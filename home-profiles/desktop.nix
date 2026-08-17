{
  user,
  config,
  lib,
  ...
}:
let
  username = user;
in
{
  imports = [
    ../modules/data/sync-hosts.nix
    ../modules/data/nas-mounts.nix
    ../modules/services/sync-compose.nix
    ../modules/services/nas-home.nix
  ];

  # Desktops are the only machines that push to Attic by hand -- the shell
  # helper in dotfiles/shell/40-functions.sh runs `attic push` for the
  # home-manager, per-user and current-system closures. Everything else in the
  # fleet pulls anonymously and gets no credential.
  #
  # The matching sops secret is declared in profiles/desktop.nix. Setting this
  # switches ~/.config/attic/config.toml from a store symlink to a real 0600
  # file rendered at activation, so the token never enters the Nix store.
  programs.atticClient.tokenFile = lib.mkDefault "/run/secrets/attic/desktop_token";

  programs.sync-compose = {
    enable = lib.mkDefault true;
    user = lib.mkDefault username;
    hosts = lib.mkDefault config.shared.syncHosts;
  };

  nas = {
    enable = lib.mkDefault true;
    mounts = lib.mkDefault config.shared.nasMounts.standard;
  };
}
