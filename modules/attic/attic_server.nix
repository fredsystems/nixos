{
  config,
  ...
}:
{
  sops.secrets = {
    "atticd_env" = { };
  };

  services.atticd = {
    enable = true;

    environmentFile = config.sops.secrets."atticd_env".path;

    settings = {
      listen = "[::]:8080";
      jwt = { };

      # We’ll tune chunking later; defaults are fine for now.
      chunking = {
        nar-size-threshold = 64 * 1024;
        min-size = 16 * 1024;
        avg-size = 64 * 1024;
        max-size = 256 * 1024;
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
