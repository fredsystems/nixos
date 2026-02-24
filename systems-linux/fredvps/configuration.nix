{
  pkgs,
  lib,
  stateVersion,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix
    ../../profiles/adsb-hub.nix
  ];

  # Not on the LAN - exclude from the monitoring agent mesh until Tailscale is set up.
  deployment.role = "standalone";

  # The local Attic cache (192.168.31.14) is unreachable from the VPS — use
  # only the public cache until Tailscale is set up.
  nix.settings.substituters = lib.mkForce [ "https://cache.nixos.org" ];

  # The common packages module unconditionally enables systemd-boot; override
  # since this VPS uses GRUB (BIOS boot, no EFI).
  boot = {
    # Boot - GRUB on /dev/sda (VPS, BIOS boot, no EFI)
    loader = {
      systemd-boot.enable = lib.mkForce false;
      efi.canTouchEfiVariables = lib.mkForce false;
      grub = {
        enable = true;
        device = "/dev/sda";
        useOSProber = false;
      };
    };

    # Use latest kernel
    kernelPackages = pkgs.linuxPackages_latest;
  };

  # Secondary user — mirrors the groups and packages that users/user/default.nix
  # gives fred, but declared locally since mkSystem only wires up one system user.
  users.users.nik = {
    linger = true;
    isNormalUser = true;
    description = "Nik";
    extraGroups = [
      "networkmanager"
      "wheel"
      "docker"
      "wireshark"
    ];
    packages = with pkgs; [
      gh
      stow
      rtl-sdr-librtlsdr
      rrdtool
    ];
  };

  system.stateVersion = stateVersion;

  # Networking - NetworkManager with IPv4 DHCP and static IPv6.
  # useDHCP = false lets NM own all interfaces; DHCP is handled by the
  # profile's ipv4.method = "auto".
  networking = {
    hostName = "fredvps";
    useDHCP = false;

    networkmanager.ensureProfiles.profiles."wan" = {
      connection = {
        id = "wan";
        type = "ethernet";
        "interface-name" = "enp1s0";
        autoconnect = "true";
      };
      ipv4 = {
        method = "auto";
      };
      ipv6 = {
        method = "manual";
        address1 = "2a01:4ff:f0:2bab::/64";
        gateway = "fe80::1";
        "ip6-privacy" = "0";
      };
    };
  };
}
