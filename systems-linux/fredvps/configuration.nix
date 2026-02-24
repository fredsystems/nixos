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
    ./nginx.nix
  ];

  # Not on the LAN - exclude from the monitoring agent mesh until Tailscale is set up.
  deployment.role = "standalone";

  # The local Attic cache (192.168.31.14) is unreachable from the VPS — use
  # only the public cache until Tailscale is set up.
  nix.settings.substituters = lib.mkForce [ "https://cache.nixos.org" ];

  # The common packages module unconditionally enables systemd-boot and
  # networkmanager; override both since this VPS uses GRUB + systemd-networkd.
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

  networking = {
    hostName = "fredvps";
    useNetworkd = true;
    useDHCP = false;
    networkmanager.enable = lib.mkForce false;
  };

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

  system.activationScripts.adsbDockerCompose = {
    text = ''
      # Ensure directory exists (does not touch contents if already there)
      install -d -m0755 -o fred -g users /opt/adsb
    '';
    deps = [ ];
  };

  services = {
    adsb.containers = [
      ###############################################################
      # DOZZLE AGENT
      ###############################################################
      {
        name = "dozzle-agent";
        image = "amir20/dozzle:v10.0.4";
        exec = "agent";

        volumes = [
          "/var/run/docker.sock:/var/run/docker.sock:ro"
        ];

        ports = [ "7007:7007" ];
      }

      ###############################################################
      # IMAGE API
      ###############################################################
      {
        name = "imageapi";
        image = "ghcr.io/sdr-enthusiasts/sdre-image-api:latest-build-5";

        volumes = [
          "/opt/adsb/image-api/data:/opt/api"
        ];

        ports = [ "3001:3000" ];
      }
    ];
  };
}
