{
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  security.acme = {
    acceptTerms = true;
    defaults.email = "clausen.fred@me.com";
  };

  systemd.tmpfiles.rules = [
    "d /var/www 0755 root root -"
  ];

  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    virtualHosts = {
      "onemorefoot.com" = {
        forceSSL = true;
        enableACME = true;
        serverAliases = [ "www.onemorefoot.com" ];

        globalRedirect = "fredclausen.com";
      };

      "atcfreq.com" = {
        forceSSL = true;
        enableACME = true;
        serverAliases = [ "www.atcfreq.com" ];

        globalRedirect = "fredclausen.com";
      };

      "epicspam.com" = {
        forceSSL = true;
        enableACME = true;
        serverAliases = [ "www.epicspam.com" ];

        globalRedirect = "fredclausen.com";
      };

      "politicalpileon.com" = {
        forceSSL = true;
        enableACME = true;
        serverAliases = [ "www.politicalpileon.com" ];

        globalRedirect = "fredclausen.com";
      };

      "therightradio.com" = {
        forceSSL = true;
        enableACME = true;
        serverAliases = [ "www.therightradio.com" ];

        globalRedirect = "fredclausen.com";
      };

      "sdrdockerconfig.com" = {
        forceSSL = true;
        enableACME = true;
        serverAliases = [ "www.sdrdockerconfig.com" ];

        globalRedirect = "fredclausen.com";
      };

      "adsb-pi.com" = {
        forceSSL = true;
        enableACME = true;
        serverAliases = [ "www.adsb-pi.com" ];

        globalRedirect = "fredclausen.com";
      };

      "freminal.com" = {
        forceSSL = true;
        enableACME = true;
        serverAliases = [ "www.freminal.com" ];

        globalRedirect = "fredclausen.com";
      };

      "sdr-e.org" = {
        forceSSL = true;
        enableACME = true;
        serverAliases = [ "www.sdr-e.org" ];

        globalRedirect = "github.com/sdr-enthusiasts";
      };

      "sdr-enthusiasts.org" = {
        forceSSL = true;
        enableACME = true;
        serverAliases = [ "www.sdr-enthusiasts.org" ];

        globalRedirect = "github.com/sdr-enthusiasts";
      };

      "fredclausen.com" = {
        forceSSL = true;
        enableACME = true;
        serverAliases = [ "www.fredclausen.com" ];

        locations = {
          "/" = {
            proxyPass = "http://127.0.0.1:4200/";
          };

          "/cider-v3.1.8-linux-x64.AppImage" = {
            root = "/var/www";
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
