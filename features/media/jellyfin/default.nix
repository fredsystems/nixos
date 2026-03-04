{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.media.jellyfin;
  mediaMount = "/mnt/media";
in
{
  options.media.jellyfin = {
    enable = mkEnableOption "Enable Jellyfin media server";
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ pkgs.nfs-utils ];

    ############################################
    # NFS MEDIA MOUNT
    ############################################

    fileSystems.${mediaMount} = {
      device = "192.168.31.16:/volume1/Media";
      fsType = "nfs";
      options = [
        "rw"
        "noatime"
        "nfsvers=3"
        "x-systemd.idle-timeout=600"
        "_netdev"
      ];
    };

    systemd = {
      automounts = [
        {
          where = "/mnt/media";
          wantedBy = [ "multi-user.target" ];
        }
      ];

      mounts = [
        {
          what = "192.168.31.16:/volume1/Media";
          where = "/mnt/media";
          type = "nfs";
          options = "rw,noatime,nfsvers=3,_netdev";
        }
      ];

      services.jellyfin = {
        after = [
          "network-online.target"
        ];
        wants = [ "network-online.target" ];
      };
    };

    ############################################
    # JELLYFIN SERVICE
    ############################################

    services.jellyfin = {
      enable = true;
      openFirewall = true;
      user = "jellyfin";
      group = "jellyfin";
    };

    ############################################
    # PERMISSIONS
    ############################################

    users.users.jellyfin = {
      isSystemUser = true;
      extraGroups = [
        "video" # future HW transcoding
      ];
    };

    ############################################
    # GRAPHICS (SAFE EVEN IF UNUSED)
    ############################################

    hardware.graphics.enable = true;
  };
}
