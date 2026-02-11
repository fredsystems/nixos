{ lib, ... }:
{
  # Define standard NAS mounts that can be imported by any system
  options.shared.nasMounts = lib.mkOption {
    type = lib.types.attrsOf (lib.types.listOf lib.types.attrs);
    default = {
      standard = [
        {
          path = "/mnt/nas/fred";
          host = "192.168.31.16";
          share = "/volume1/Fred Share";
          type = "nfs";
          gvfsName = "Fred Share";
        }
        {
          path = "/mnt/nas/discord";
          host = "192.168.31.16";
          share = "/volume1/discord";
          type = "nfs";
          gvfsName = "Discord";
        }
        {
          path = "/mnt/nas/dropbox";
          host = "192.168.31.16";
          share = "/volume1/Dropbox";
          type = "nfs";
          gvfsName = "Dropbox";
        }
        {
          path = "/mnt/nas/media";
          host = "192.168.31.16";
          share = "/volume1/Media";
          type = "nfs";
          gvfsName = "Media";
        }
        {
          path = "/mnt/nas/prometheus";
          host = "192.168.31.16";
          share = "/volume1/Prometheus";
          type = "nfs";
          gvfsName = "Prometheus";
        }
      ];
    };
    description = "Centralized NAS mount definitions";
  };
}
