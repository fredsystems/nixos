{
  pkgs,
  stateVersion,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
    ../../profiles/adsb-hub.nix
  ];

  networking.hostName = "fredvps";

  system.stateVersion = stateVersion;

  # Boot - GRUB on /dev/sda (VPS, BIOS boot, no EFI)
  boot.loader.grub = {
    enable = true;
    device = "/dev/sda";
    useOSProber = false;
  };

  # Use latest kernel
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Networking - systemd-networkd with IPv4 DHCP and static IPv6
  systemd.network = {
    enable = true;
    networks."10-wan" = {
      matchConfig.Name = "enp1s0";
      networkConfig = {
        DHCP = "ipv4";
        IPv6AcceptRA = false;
      };
      address = [
        "2a01:4ff:f0:2bab::/64"
      ];
      routes = [
        { routeConfig.Gateway = "fe80::1"; }
      ];
    };
  };

  networking = {
    useNetworkd = true;
    useDHCP = false;
  };
}
