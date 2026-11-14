{
  imports = [
    ./hardware-configuration.nix
    ../../../modules/secrets/sops.nix
  ];

  # Base install only (Plan 05, 5.2). The ADS-B and ACARS containers move here
  # from sdrhub in 5.4.
  networking.hostName = "adsbhub";

  sops_secrets.enable_secrets.enable = true;
}
