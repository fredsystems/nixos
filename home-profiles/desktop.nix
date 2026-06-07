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
