{
  user,
  config,
  inputs,
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
  programs.ansible.enable = true;

  programs.sync-compose = {
    enable = true;
    user = username;
    hosts = config.shared.syncHosts;
  };

  nas = {
    enable = true;
    mounts = config.shared.nasMounts.standard;
  };
}
