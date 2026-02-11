{
  user,
  config,
  ...
}:
let
  username = user;
in
{
  # ------------------------------
  # Host-specific Home Manager overrides for Freds-MacBook-Pro
  # ------------------------------

  imports = [
    ../../shared/sync-hosts.nix
    ../../modules/sync-compose.nix
    ../../modules/ansible/ansible.nix
  ];

  programs.ansible.enable = true;

  services.yubikey-agent.enable = true;

  programs.sync-compose = {
    enable = true;
    user = username;
    hosts = config.shared.syncHosts;
  };
}
