{
  config,
  ...
}:
{
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  security.acme = {
    acceptTerms = true;
    defaults.email = "clausen.fred@me.com";

    certs = {
      "fredclausen.com" = {
        group = config.services.nginx.group;
        extraDomainNames = [
          "www.fredclausen.com"
        ];
      };
    };
  };

  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    virtualHosts."fredclausen.com" = {
      forceSSL = true;
      serverAliases = [ "www.fredclausen.com" ];
      useACMEHost = "fredclausen.com";

      locations = {
        "/.well-known/".root = "/var/lib/acme/acme-challenge/";

        "/" = {
          return = "200 'Coming soon'";
          extraConfig = "add_header Content-Type text/plain;";
        };
      };
    };
  };
}
