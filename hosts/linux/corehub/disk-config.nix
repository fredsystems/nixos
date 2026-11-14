# disko layout, read by nixos-anywhere at install time and by the host for its
# fileSystems. Wired by flake/hosts/nixos.nix through this node's
# `diskConfig` in flake/hosts/servers.nix.
#
# The device is named by /dev/disk/by-id, read off the live installer with
# `ls -l /dev/disk/by-id`, never /dev/sdX or /dev/nvmeXnY: those are assigned
# at probe time, and nixos-anywhere wipes whatever this names.
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/disk/by-id/nvme-GMK_256GB_AA202608132092";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [
              "fmask=0077"
              "dmask=0077"
            ];
          };
        };
        swap = {
          size = "8G";
          content.type = "swap";
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
