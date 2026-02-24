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

    virtualHosts = {
      "fredclausen.com" = {
        forceSSL = true;
        enableACME = true;
        serverAliases = [ "www.fredclausen.com" ];

        locations = {
          "/" = {
            return = "200 'Coming soon'";
            extraConfig = "add_header Content-Type text/plain;";
          };

          "/cider-v3.1.8-linux-x64.AppImage" = {
            alias = "/home/fred/cider-v3.1.8-linux-x64.AppImage";
            # extraConfig = ''
            #   add_header Content-Type application/octet-stream;
            #   add_header Content-Disposition "attachment; filename=cider-v3.1.8-linux-x64.AppImage";
            # '';
          };

          "/acarshub/" = {
            proxyPass = "http://127.0.0.1:8085/";
            proxyWebsockets = true;
            extraConfig = ''
              proxy_redirect / /acarshub/;
              proxy_set_header X-Forwarded-Prefix /acarshub;
            '';
          };

          "/imageapi/" = {
            proxyPass = "http://127.0.0.1:3001/";
            proxyWebsockets = true;
            extraConfig = ''
              proxy_redirect / /imageapi/;
              proxy_set_header X-Forwarded-Prefix /imageapi;
            '';
          };

          "/tar1090/" = {
            proxyPass = "http://127.0.0.1:8081/";
            extraConfig = ''
              proxy_redirect / /tar1090/;
              proxy_set_header X-Forwarded-Prefix /tar1090;
            '';
          };
        };
      };

      "acarshub.app" = {
        forceSSL = true;
        enableACME = true;
        serverAliases = [ "www.acarshub.app" ];

        locations."/" = {
          proxyPass = "http://127.0.0.1:8085/";
          proxyWebsockets = true;
        };
      };

      "acarshub.com" = {
        forceSSL = true;
        enableACME = true;
        serverAliases = [ "www.acarshub.com" ];
        globalRedirect = "acarshub.app";
      };
    };
  };
}
