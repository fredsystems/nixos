{ config, ... }:
{
  sops.secrets."tailscale/authkey" = {
    mode = "0400";
  };

  services.tailscale = {
    enable = true;
    authKeyFile = config.sops.secrets."tailscale/authkey".path;
    openFirewall = true;
  };
}
