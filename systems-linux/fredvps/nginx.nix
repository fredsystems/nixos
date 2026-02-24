{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Add domains here. Each entry gets its own SSL cert, bind zone, and nginx vhost.
  #
  # Options per domain:
  #   domain       - apex domain name (also used as the ACME cert name)
  #   extraDomains - additional SANs on the cert (e.g. www); also added as nginx serverAliases
  #   locations    - nginx location blocks (attrset passed directly to virtualHosts)
  domains = [
    {
      domain = "fredclausen.com";
      extraDomains = [ "www.fredclausen.com" ];
      locations = {
        "/" = {
          return = "200 'Coming soon'";
          extraConfig = "add_header Content-Type text/plain;";
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
    }
  ];

  # Shared TSIG key name — server-scoped, not domain-scoped.
  # All bind zones and the ACME RFC2136 provider use this single key.
  tsigKeyName = "rfc2136key.fredvps";

  domainNames = map (d: d.domain) domains;
in
{
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  # One bind zone per domain, all permitting updates via the shared TSIG key.
  services.bind = {
    enable = true;
    extraConfig = ''
      include "/var/lib/secrets/dnskeys.conf";
    '';
    zones = map (d: {
      name = d.domain;
      file = "/var/db/bind/${d.domain}";
      master = true;
      extraConfig = "allow-update { key ${tsigKeyName}.; };";
    }) domains;
  };

  # Generates the shared TSIG key and the certs.secret env file consumed by
  # the RFC2136 ACME provider. Runs once (skipped if key already exists),
  # before bind and all ACME cert services.
  systemd.services.dns-rfc2136-conf = {
    requiredBy = map (d: "acme-${d}.service") domainNames;
    before = map (d: "acme-${d}.service") domainNames ++ [ "bind.service" ];
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
      tsig-keygen ${tsigKeyName} > /var/lib/secrets/dnskeys.conf
      chown named:root /var/lib/secrets/dnskeys.conf
      chmod 400 /var/lib/secrets/dnskeys.conf

      # Extract the secret value from the generated key file
      while read x y; do
        if [ "$x" = "secret" ]; then secret="''${y:1:''${#y}-3}"; fi
      done < /var/lib/secrets/dnskeys.conf

      cat > /var/lib/secrets/certs.secret << EOF
      RFC2136_NAMESERVER='127.0.0.1:53'
      RFC2136_TSIG_ALGORITHM='hmac-sha256.'
      RFC2136_TSIG_KEY='${tsigKeyName}'
      RFC2136_TSIG_SECRET='$secret'
      EOF
      chmod 400 /var/lib/secrets/certs.secret
    '';
  };

  # One ACME cert per domain — each fully independent, DNS-01 via RFC2136.
  security.acme = {
    acceptTerms = true;
    defaults.email = "clausen.fred@me.com";

    certs = lib.listToAttrs (
      map (d: {
        name = d.domain;
        value = {
          inherit (config.services.nginx) group;
          extraDomainNames = d.extraDomains;
          dnsProvider = "rfc2136";
          environmentFile = "/var/lib/secrets/certs.secret";
          # No propagation delay needed — we control the DNS server directly
          dnsPropagationCheck = false;
        };
      }) domains
    );
  };

  # One nginx vhost per domain, each referencing its own ACME cert.
  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    virtualHosts = lib.listToAttrs (
      map (d: {
        name = d.domain;
        value = {
          forceSSL = true;
          serverAliases = d.extraDomains;
          useACMEHost = d.domain;
          inherit (d) locations;
        };
      }) domains
    );
  };
}
