{
  stateVersion,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
    ../../../profiles/adsb-hub.nix
  ];

  networking.hostName = "nvrhub";

  system.stateVersion = stateVersion;
}
