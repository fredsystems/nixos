{
  imports = [
    ./hardware-configuration.nix
    ../../../modules/secrets/sops.nix
  ];

  # Base install only (Plan 05, 5.2). DNS, nginx, the monitoring master and
  # the remaining sdrhub services move here in 5.6.
  networking.hostName = "corehub";

  sops_secrets.enable_secrets.enable = true;
}
