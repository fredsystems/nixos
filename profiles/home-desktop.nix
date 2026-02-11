{
  user,
  config,
  inputs,
  lib,
  ...
}:
let
  username = user;
in
{
  imports = [
    inputs.fredbar.homeManagerModules.fredbar
    ../shared/sync-hosts.nix
    ../shared/nas-mounts.nix
    ../modules/sync-compose.nix
    ../modules/ansible/ansible.nix
    ../modules/nas-home.nix
  ];

  # Enable common desktop services
  programs.ansible.enable = lib.mkDefault true;

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
