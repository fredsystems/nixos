# Placeholder until install. nixos-anywhere overwrites this file with the
# output of `nixos-generate-config --no-filesystems` run on the target
# (Plan 05, 5.3); filesystems come from ./disk-config.nix.
{ lib, ... }:
{
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "nvme"
    "usb_storage"
    "sd_mod"
  ];

  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
