{
  config,
  pkgs,
  ...
}:
{
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  services.bind = {
    enable = true;
    extraConfig = ''
      include "/var/lib/secrets/dnskeys.conf";
    '';
    zones = [
      rec {
        name = "fredclausen.com";
        file = "/var/db/bind/${name}";
        master = true;
        extraConfig = "allow-update { key rfc2136key.fredclausen.com.; };";
      }
    ];
  };

  systemd.services.dns-rfc2136-conf = {
    requiredBy = [
      "acme-fredclausen.com.service"
      "bind.service"
    ];
    before = [
      "acme-fredclausen.com.service"
      "bind.service"
    ];
    unitConfig = {
      ConditionPathExists = "!/var/lib/secrets/dnskeys.conf";
    };
    serviceConfig = {
      Type = "oneshot";
      UMask = 77;
    };
    path = [ pkgs.bind ];
    script = ''
      mkdir -p /var/lib/secrets
      chmod 755 /var/lib/secrets
      tsig-keygen rfc2136key.example.com > /var/lib/secrets/dnskeys.conf
      chown named:root /var/lib/secrets/dnskeys.conf
      chmod 400 /var/lib/secrets/dnskeys.conf

      # extract secret value from the dnskeys.conf
      while read x y; do if [ "$x" = "secret" ]; then secret="''${y:1:''${#y}-3}"; fi; done < /var/lib/secrets/dnskeys.conf

      cat > /var/lib/secrets/certs.secret << EOF
      RFC2136_NAMESERVER='127.0.0.1:53'
      RFC2136_TSIG_ALGORITHM='hmac-sha256.'
      RFC2136_TSIG_KEY='rfc2136key.example.com'
      RFC2136_TSIG_SECRET='$secret'
      EOF
      chmod 400 /var/lib/secrets/certs.secret
    '';
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "clausen.fred@me.com";

    certs = {
      "fredclausen.com" = {
        group = config.services.nginx.group;
        extraDomainNames = [
          "www.fredclausen.com"
        ];

        dnsProvider = "rfc2136";
        environmentFile = "/var/lib/secrets/certs.secret";
        # We don't need to wait for propagation since this is a local DNS server
        dnsPropagationCheck = false;
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
      enableACME = true;
      acmeRoot = null;
      # useACMEHost = "fredclausen.com";

      locations = {
        "/" = {
          return = "200 'Coming soon'";
          extraConfig = "add_header Content-Type text/plain;";
        };
      };
    };
  };
}
