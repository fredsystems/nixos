{ pkgs, ... }:
let
  # Blackbox exporter listen address. Deliberately loopback-only.
  #
  # Nothing outside this host has any reason to reach the exporter: it is a
  # probe *driver*, not a source of truth about sdrhub, and the only consumer
  # is the Prometheus instance running on this same machine. Binding it to
  # 0.0.0.0 would expose an unauthenticated HTTP fetcher on the LAN --
  # /probe?target=<anything> turns the exporter into an open SSRF relay that
  # can reach every LAN service the firewall otherwise protects.
  #
  # Consequently there is NO networking.firewall.allowedTCPPorts entry in this
  # file, and services.prometheus.exporters.blackbox.openFirewall stays at its
  # default of false. Port 9115 is the upstream default and is unused elsewhere
  # in this repo (sdrhub already occupies 22, 80, 3000, 3333, 4567, 5432, 5678,
  # 6379, 8889, 9090, 9093, 9100 and 11434).
  blackboxHost = "127.0.0.1";
  blackboxPort = 9115;
  blackboxAddress = "${blackboxHost}:${toString blackboxPort}";

  # Public HTTPS vhosts on fredvps that terminate TLS with their own ACME
  # certificate. See hosts/linux/fredvps/nginx.nix -- every one of these is a
  # separate `enableACME = true` vhost, so every one has an independently
  # issued certificate that can independently fail to renew. That is precisely
  # why the whole set is probed rather than a token sample: a per-cert renewal
  # failure is invisible if only one cert is watched.
  #
  # Split by expected response so the probe asserts the *intended* behaviour
  # instead of accepting any 2xx-or-3xx. Every entry below was verified to
  # respond as classified, from sdrhub, with a clean chain (ssl_verify_result=0).

  # Vhosts that serve real content and must answer 2xx directly.
  publicAppEndpoints = [
    "https://fredclausen.com/" # nginx -> fredsite on 127.0.0.1:4200
    "https://acarshub.app/" # nginx -> acarshub on 127.0.0.1:8085
    "https://flipaholics.pro/" # nginx -> 127.0.0.1:8078
  ];

  # Vhosts whose entire job is a globalRedirect. These must answer 3xx; a 2xx
  # here would mean the redirect silently stopped working.
  publicRedirectEndpoints = [
    "https://acarshub.com/" # -> acarshub.app
    "https://adsb-pi.com/" # -> fredclausen.com
    "https://atcfreq.com/" # -> fredclausen.com
    "https://epicspam.com/" # -> fredclausen.com
    "https://freminal.com/" # -> fredclausen.com
    "https://onemorefoot.com/" # -> fredclausen.com
    "https://politicalpileon.com/" # -> fredclausen.com
    "https://sdrdockerconfig.com/" # -> fredclausen.com
    "https://therightradio.com/" # -> fredclausen.com
    "https://sdr-e.org/" # -> github.com/sdr-enthusiasts
    "https://sdr-enthusiasts.org/" # -> github.com/sdr-enthusiasts
  ];

  # LAN-only HTTP vhosts served by nginx on this host (see the virtualHosts
  # block in hosts/linux/sdrhub/configuration.nix).
  #
  # These are NOT redundant with the existing `up` metric. Prometheus scrapes
  # the backends directly on their container ports; nothing currently exercises
  # the nginx reverse-proxy layer in front of them. A broken proxyPass, a
  # dropped serverAlias, or an AdGuard rewrite that stops resolving leaves
  # every `up` at 1 while the service is unreachable for every human. This is
  # the only check that covers that path.
  #
  # Each was verified 200 from sdrhub itself (dump978 after following its
  # single redirect to /skyaware978/, which is why the internal module follows
  # redirects and the public ones do not).
  internalEndpoints = [
    "http://sdrhub.local/" # landing page
    "http://tar1090.sdrhub.local/" # -> 192.168.31.20:8080
    "http://dump978.sdrhub.local/" # -> 192.168.31.20:8083
    "http://piaware.sdrhub.local/" # -> 192.168.31.20:8084
    "http://ai.sdrhub.local/" # -> fredhub 192.168.31.14:8889
    "http://search.sdrhub.local/" # -> 127.0.0.1:4444
  ];

  # The relabel dance is the entire trick of a blackbox scrape job, and it is
  # silently wrong if any step is missing:
  #
  #   1. __address__ (the URL to probe) is copied into __param_target, which
  #      Prometheus renders as the ?target= query parameter on /probe.
  #   2. instance is set from __param_target so the resulting series are
  #      labelled with the probed URL rather than with the exporter.
  #   3. ONLY THEN is __address__ overwritten with the exporter's own
  #      host:port, which is what Prometheus actually connects to.
  #
  # Omit step 3 and Prometheus tries to scrape /probe on the target itself.
  # Omit steps 1-2 and the exporter receives no target, returns its own
  # metrics, and every series is labelled with the exporter -- a job that looks
  # perfectly healthy while probing nothing. Order matters: step 2 reads the
  # label step 1 writes, and step 3 must come last.
  probeRelabelConfigs = [
    {
      source_labels = [ "__address__" ];
      target_label = "__param_target";
    }
    {
      source_labels = [ "__param_target" ];
      target_label = "instance";
    }
    {
      target_label = "__address__";
      replacement = blackboxAddress;
    }
  ];

  mkProbeJob = name: module: targets: {
    job_name = name;
    metrics_path = "/probe";
    params.module = [ module ];
    # Probes are far more expensive than a metrics fetch and TLS expiry moves
    # on a scale of days, so override the 15s global interval.
    scrape_interval = "60s";
    # Must exceed the module timeout below, or Prometheus gives up before the
    # exporter can report a failure and the result is `up == 0` instead of the
    # much more informative `probe_success == 0`.
    scrape_timeout = "15s";
    static_configs = [ { inherit targets; } ];
    relabel_configs = probeRelabelConfigs;
  };

  # preferred_ip_protocol must be ip4 on every module: upstream defaults to
  # ip6, and this network has no IPv6 route at all (`ip -6 route get` returns
  # "Network is unreachable" on sdrhub, and fredvps' A records only resolve to
  # v4-mapped addresses). Leaving the default would make every probe fail, or
  # at best add a pointless timeout before ip_protocol_fallback kicks in.
  #
  # fail_if_not_ssl on the HTTPS modules guards against a target being
  # downgraded to plain HTTP without anyone noticing -- with
  # follow_redirects disabled it cannot happen via a redirect, but it can
  # happen by editing a target URL here.
  blackboxConfig = {
    modules = {
      # follow_redirects = false so probe_ssl_earliest_cert_expiry describes
      # THIS host's certificate. The exporter reads TLS state off the *final*
      # response in the chain (prober/http.go sets the gauge from `resp.TLS`),
      # so following redirects on acarshub.com would silently report
      # acarshub.app's expiry, and sdr-e.org would report github.com's. The
      # cert-expiry alerts would then be watching the wrong certificates.
      https_2xx = {
        prober = "http";
        timeout = "10s";
        http = {
          method = "GET";
          valid_status_codes = [ ]; # empty = any 2xx
          follow_redirects = false;
          fail_if_not_ssl = true;
          preferred_ip_protocol = "ip4";
        };
      };

      https_redirect = {
        prober = "http";
        timeout = "10s";
        http = {
          method = "GET";
          valid_status_codes = [
            301
            302
            307
            308
          ];
          follow_redirects = false;
          fail_if_not_ssl = true;
          preferred_ip_protocol = "ip4";
        };
      };

      # Internal LAN vhosts. Redirects are followed here because dump978's
      # container redirects / -> /skyaware978/ and the end state is what
      # matters; there is no certificate to attribute to the wrong host.
      http_2xx = {
        prober = "http";
        timeout = "10s";
        http = {
          method = "GET";
          valid_status_codes = [ ];
          follow_redirects = true;
          fail_if_ssl = true;
          preferred_ip_protocol = "ip4";
        };
      };
    };
  };

  blackboxConfigFile = (pkgs.formats.yaml { }).generate "blackbox-exporter.yml" blackboxConfig;
in
{
  services.prometheus = {
    exporters.blackbox = {
      enable = true;
      listenAddress = blackboxHost;
      port = blackboxPort;
      configFile = blackboxConfigFile;
    };

    # Plain assignment, never lib.mkDefault.
    #
    # ruleFiles and scrapeConfigs are list options, and a mkDefault list is not
    # merged with normal-priority definitions -- it is discarded wholesale by
    # them. Wrapping either of these in mkDefault would delete every rule file
    # and scrape job declared in prometheus.nix the moment this module loaded.
    # That exact bug was just fixed in modules/hardware/rtl-sdr.nix. Normal
    # priority makes the module system concatenate instead, which is verified
    # by asserting the pre-existing job names survive:
    #
    #   nix eval --json '.#nixosConfigurations.sdrhub.config.services.prometheus.scrapeConfigs'
    ruleFiles = [
      ./alert-rules/blackbox-alerts.yaml
    ];

    scrapeConfigs = [
      (mkProbeJob "blackbox-https" "https_2xx" publicAppEndpoints)
      (mkProbeJob "blackbox-https-redirect" "https_redirect" publicRedirectEndpoints)
      (mkProbeJob "blackbox-http-internal" "http_2xx" internalEndpoints)

      # The exporter's own operational metrics -- not a probe, a normal scrape.
      # Without this, a dead exporter yields no probe_success series at all,
      # and "no series" never fires an alert. This job gives the existing
      # PrometheusTargetDown rule something to notice.
      {
        job_name = "blackbox-exporter";
        static_configs = [
          {
            targets = [ blackboxAddress ];
            labels = {
              hostname = "sdrhub";
              role = "master";
              exporter = "blackbox";
            };
          }
        ];
      }
    ];
  };
}
