{
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  security.acme = {
    acceptTerms = true;
    defaults.email = "clausen.fred@me.com";
  };

  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    virtualHosts."fredclausen.com" = {
      enableACME = true;
      forceSSL = true;
      serverAliases = [ "www.fredclausen.com" ];

      locations."/" = {
        return = "200 'Coming soon'";
        extraConfig = "add_header Content-Type text/plain;";
      };
    };
  };
}
