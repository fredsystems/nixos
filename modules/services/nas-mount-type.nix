# Shared NAS mount submodule type used by both nas-system.nix and nas-home.nix.
{ lib }:
lib.types.submodule {
  options = {
    path = lib.mkOption { type = lib.types.str; };
    host = lib.mkOption { type = lib.types.str; };
    share = lib.mkOption { type = lib.types.str; };
    type = lib.mkOption {
      type = lib.types.enum [
        "nfs"
        "smb"
      ];
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
    };
  };
}
