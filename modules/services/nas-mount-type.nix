# Shared NAS mount submodule type used by both nas-system.nix and nas-home.nix.
{ lib }:
lib.types.submodule {
  options = {
    path = lib.mkOption {
      type = lib.types.str;
      description = "Local mount point, as an absolute path (e.g. \"/mnt/nas/fred\").";
    };
    host = lib.mkOption {
      type = lib.types.str;
      description = "Hostname or IP address of the NAS exporting this share.";
    };
    share = lib.mkOption {
      type = lib.types.str;
      description = "Name of the exported NFS share or SMB share on the NAS.";
    };
    type = lib.mkOption {
      type = lib.types.enum [
        "nfs"
        "smb"
      ];
      description = "Protocol used to mount the share; selects the fstab/gio mount options.";
    };
    wifi = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Only mount when connected to this SSID.";
    };
    gvfsName = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Display name used by the Home Manager NAS module.";
    };
    extraOptions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional mount options appended after the type-specific defaults.";
    };
  };
}
