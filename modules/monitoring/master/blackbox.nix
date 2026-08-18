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
  #
  # PRIMARY endpoints: exactly one per TLS certificate. The cert-expiry rules in
  # alert-rules/blackbox-alerts.yaml select on these jobs alone, so this list and
  # publicRedirectEndpoints below must stay one-target-per-certificate. Anything
  # sharing a cert with an entry here belongs in the *Secondary lists.
  publicAppEndpoints = [
    "https://fredclausen.com/" # nginx -> fredsite on 127.0.0.1:4200
    "https://acarshub.app/" # nginx -> acarshub on 127.0.0.1:8085
    "https://flipaholics.pro/" # nginx -> 127.0.0.1:8078
  ];

  # Additional 2xx targets that share a certificate with a primary endpoint
  # above, so they are probed for availability but excluded from the cert-expiry
  # rules. Without that split every shared cert would be reported twice, on two
  # instance labels, for one renewal fault.
  #
  # Two groups:
  #
  #   * www aliases. Every vhost in fredvps/nginx.nix carries
  #     `serverAliases = [ "www.<domain>" ]`, and the nginx module folds those
  #     into the same ACME cert -- so expiry is already covered by the apex, but
  #     *availability* is not. A dropped or typo'd serverAlias breaks www.* while
  #     the apex stays green and nothing notices. This file already justifies the
  #     internal probes with exactly that reasoning; the public set was
  #     inconsistent with it.
  #
  #   * Sub-path applications on fredclausen.com. The apex probe only exercises
  #     `/` (fredsite on :4200). Two further backends hang off path prefixes on
  #     that same vhost and had no availability coverage at all: nothing scrapes
  #     them, so either could be down while `https://fredclausen.com/` still
  #     answered 200. `/acarshub/` is deliberately omitted -- it proxies to the
  #     same :8085 the acarshub.app probe already covers.
  #
  # Verified as classified: every entry below answers 200, and every www alias
  # answers exactly as its apex does.
  publicAppSecondaryEndpoints = [
    "https://www.fredclausen.com/"
    "https://www.acarshub.app/"
    "https://www.flipaholics.pro/"

    # tar1090 container on 127.0.0.1:8081.
    "https://fredclausen.com/tar1090/"

    # imageapi (sdre-image-api) on 127.0.0.1:3001. Probes a real route rather
    # than the prefix root: the app is an Express API with no `/` handler, so
    # `/imageapi/` answers 404 by design and a 2xx probe there would fire
    # permanently. This route also exercises the app's database, since it reads
    # the newest lastUpdated row. Freshness of that value is a separate concern
    # and is covered by the imageapi_last_updated_seconds metric on
    # fredvps -- blackbox can assert a status code but cannot compute an age.
    "https://fredclausen.com/imageapi/api/v1/last-updated"
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

  # www aliases of the redirect vhosts. Same rationale as
  # publicAppSecondaryEndpoints: shared certificate, so availability-only.
  # All eleven were verified to answer 301, identically to their apex.
  publicRedirectSecondaryEndpoints = [
    "https://www.acarshub.com/"
    "https://www.adsb-pi.com/"
    "https://www.atcfreq.com/"
    "https://www.epicspam.com/"
    "https://www.freminal.com/"
    "https://www.onemorefoot.com/"
    "https://www.politicalpileon.com/"
    "https://www.sdrdockerconfig.com/"
    "https://www.therightradio.com/"
    "https://www.sdr-e.org/"
    "https://www.sdr-enthusiasts.org/"
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
  # Endpoints that legitimately answer 401 unauthenticated. Probing these with
  # a 2xx module would fire permanently; the point of the probe is to prove
  # nginx still reaches a live upstream, and a 401 proves exactly that without
  # putting a credential in the exporter.
  #
  # This target's module asserts `fail_if_not_ssl`. That is the exact inverse
  # of the `fail_if_ssl` these internal probes used to assert, back when every
  # vhost here was plain HTTP by design. The inversion is not optional
  # bookkeeping: leaving a migrated target on a module that asserts plaintext
  # produces a probe that keeps reporting success while asserting something
  # that is no longer true, which is strictly worse than one that fails.
  internalTlsAuthedEndpoints = [
    "https://clipboard.int.fredsystems.org/" # -> 127.0.0.1:5033 (syncclipboard)
  ];

  # The rest of the TLS vhosts on this host, all sharing the one wildcard
  # certificate. See hosts/linux/sdrhub/configuration.nix.
  #
  # This is now every vhost that answers 2xx, rather than the six that
  # happened to be probed before. jellyfin and karma had been omitted only
  # because neither had ever been verified to answer 2xx unauthenticated --
  # adding an unverified target is how a permanently-red probe gets made --
  # and both were confirmed 200 during the TLS migration.
  #
  # jellyfin needs the module's follow_redirects: it answers 302 on / and
  # serves the app from /web/. Same reason dump978 needs it.
  internalEndpoints = [
    "https://sdrhub.int.fredsystems.org/" # landing page
    "https://tar1090.int.fredsystems.org/" # -> 192.168.31.20:8080
    "https://dump978.int.fredsystems.org/" # -> 192.168.31.20:8083
    "https://piaware.int.fredsystems.org/" # -> 192.168.31.20:8084
    "https://ai.int.fredsystems.org/" # -> fredhub 192.168.31.14:8889
    "https://search.int.fredsystems.org/" # -> 127.0.0.1:4444
    "https://jellyfin.int.fredsystems.org/" # -> fredhub 192.168.31.14:8096
    "https://karma.int.fredsystems.org/" # -> 127.0.0.1 (karma.nix)

    # Synology DSM on the NAS. Verified 200 on `/` over both :5000 and :5001,
    # so there is no redirect to follow -- this job's module follows them
    # regardless, for dump978's sake.
    #
    # This one earns its probe for a reason the others do not have: its upstream
    # is the only service behind this nginx that is NOT managed by this flake. A
    # DSM update that moves a port, or an admin toggle that turns off the HTTPS
    # listener, changes the proxy target with no commit in this repository to
    # review and no `up` metric to drop. Nothing else here would report it.
    "https://nas.int.fredsystems.org/" # -> NAS 192.168.31.16:5001 (DSM, TLS upstream)

    # AdGuard Home's admin UI, which answers 200 on / directly (verified from
    # sdrhub). Worth probing beyond the DNS probes above: those prove resolution
    # works, this proves the control plane is still reachable to fix it when it
    # does not.
    "https://adguard.int.fredsystems.org/" # -> 127.0.0.1:3003

    # /api/health rather than /, deliberately. Grafana answers 302 -> /login on
    # `/`, which the module's follow_redirects would turn into a 200 that only
    # proves the login page renders. /api/health is unauthenticated by design
    # and returns 200 only when Grafana can also reach its database, so the
    # probe fails for a broken Grafana rather than a merely reachable one.
    # Verified 200 from sdrhub.
    "https://grafana.int.fredsystems.org/api/health" # -> 127.0.0.1:3333
  ];

  # The legacy `.lan` / `.local` names. They no longer proxy anything -- each
  # is now a 308 to its TLS counterpart, kept so existing links and bookmarks
  # continue to work.
  #
  # Probed because that compatibility layer is precisely the kind of thing
  # that rots unnoticed: it has no users who would complain quickly, and its
  # whole purpose is to not break the ones it does have. A dropped
  # serverAlias or a stale AdGuard rewrite would be invisible otherwise.
  #
  # All nine are listed, unlike internalEndpoints. A redirect either is issued
  # or is not -- it does not depend on the application behind it -- so every
  # one of these can be asserted from the configuration without needing to be
  # verified against a live backend first.
  #
  # `.local` rather than `.lan`, matching the pre-existing convention here:
  # `.local` is the serverAlias, and probing the alias is what catches it
  # being dropped.
  internalRedirectEndpoints = [
    "http://sdrhub.local/"
    "http://ai.sdrhub.local/"
    "http://clipboard.sdrhub.local/"
    "http://dump978.sdrhub.local/"
    "http://jellyfin.sdrhub.local/"
    "http://karma.sdrhub.local/"
    "http://piaware.sdrhub.local/"
    "http://search.sdrhub.local/"
    "http://tar1090.sdrhub.local/"
  ];

  # DNS resolution probes.
  #
  # These exist because of a 29-minute LAN-wide external-DNS outage on
  # 2026-08-16, and an identical 8-minute one on 2026-08-15 that nobody noticed
  # at all. Neither was detected directly. The first was found by observing that
  # the healthchecks.io deadman had gone quiet and then reading journals for an
  # hour; the proximate suspect was an unrelated deploy that happened to land
  # 106 seconds before the first symptom.
  #
  # No unit-level alert could ever have caught it: AdGuard, unbound and nscd all
  # stayed `active (running)` throughout, with NRestarts=0, while the LAN had no
  # external DNS.
  #
  # WHY THREE TARGETS AND NOT ONE
  #
  # One probe tells you DNS is broken. These three tell you which layer:
  #
  #   blackbox-dns-chain     external name via AdGuard on :53   -- what clients see
  #   blackbox-dns-upstream  external name via unbound on :5335 -- excludes AdGuard
  #   blackbox-dns-rewrite   an internal rewrite via AdGuard    -- AdGuard liveness
  #
  #   chain 0, upstream 0, rewrite 1  ->  forwarders/upstream. The exact
  #                                       signature of both outages above.
  #   chain 0, upstream 1, rewrite 0  ->  AdGuard itself.
  #   chain 0, upstream 1, rewrite 1  ->  AdGuard's path to unbound.
  #   all three 0                     ->  the host, or its network.
  #
  # Probed over loopback, so these measure resolution and not reachability of
  # the box.
  dnsChainEndpoints = [ "127.0.0.1:53" ]; # AdGuard, the LAN's actual resolver
  dnsUpstreamEndpoints = [ "127.0.0.1:5335" ]; # unbound, behind AdGuard
  dnsRewriteEndpoints = [ "127.0.0.1:53" ]; # AdGuard again, local answer only

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
      # Accepts only 401. A 2xx here would mean the server stopped requiring
      # authentication, which is itself worth catching.
      #
      # follow_redirects = false. This target's certificate is the one the
      # cert-expiry rules watch, and the exporter reads TLS state off the
      # FINAL response in the chain, so following a redirect would attribute
      # some other host's expiry to this instance. syncclipboard answers 401
      # directly, so there is no redirect to follow anyway.
      https_401 = {
        prober = "http";
        timeout = "10s";
        http = {
          method = "GET";
          valid_status_codes = [ 401 ];
          follow_redirects = false;
          fail_if_not_ssl = true;
          preferred_ip_protocol = "ip4";
        };
      };

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

      # Internal LAN vhosts, all terminating TLS with the int.fredsystems.org
      # wildcard.
      #
      # Cannot just reuse https_2xx: redirects must be followed here, because
      # dump978's container redirects / -> /skyaware978/ and the end state is
      # what matters. https_2xx sets follow_redirects = false specifically to
      # keep certificate attribution correct for the public per-vhost certs.
      #
      # Following redirects is safe for attribution here only because these
      # targets are excluded from the cert-expiry rules -- their job carries
      # the `-secondary` suffix. The wildcard's expiry is watched through
      # blackbox-https-internal-authed, which does not follow.
      https_2xx_internal = {
        prober = "http";
        timeout = "10s";
        http = {
          method = "GET";
          valid_status_codes = [ ];
          follow_redirects = true;
          fail_if_not_ssl = true;
          preferred_ip_protocol = "ip4";
        };
      };

      # The legacy plaintext names, which now only issue a 308 to their TLS
      # counterpart.
      #
      # fail_if_ssl, not fail_if_not_ssl: these listeners are deliberately
      # plain HTTP. They exist to catch clients that have not moved yet, and a
      # client that could already speak TLS to them would not need them. A
      # successful handshake here means the redirect layer was reconfigured
      # into something else.
      #
      # follow_redirects = false: the assertion is that the redirect is
      # issued, not that its destination works. The destinations have their
      # own probes above, and following would make one broken TLS vhost fail
      # two jobs and obscure which layer actually broke.
      #
      # 308 rather than 301 -- see the redirect vhosts in
      # hosts/linux/sdrhub/configuration.nix for why the method must be
      # preserved.
      http_308 = {
        prober = "http";
        timeout = "10s";
        http = {
          method = "GET";
          valid_status_codes = [ 308 ];
          follow_redirects = false;
          fail_if_ssl = true;
          preferred_ip_protocol = "ip4";
        };
      };

      # Resolution of a name that can only be answered from the internet.
      #
      # example.com is chosen deliberately. It is IANA-operated, about as stable
      # as a DNS record gets, and -- the part that matters -- owned by neither
      # Quad9 nor Cloudflare. Probing a name belonging to one of the configured
      # upstreams could pass because that provider was serving its own zone,
      # while resolution of everything else was broken.
      #
      # 5s rather than the 10s used by the HTTP modules: a resolver that takes
      # longer than 5s has already failed as far as any client is concerned, and
      # a tight timeout keeps this inside the job's scrape_timeout with room to
      # spare.
      dns_external = {
        prober = "dns";
        timeout = "5s";
        dns = {
          query_name = "example.com";
          query_type = "A";
          valid_rcodes = [ "NOERROR" ];
          transport_protocol = "udp";
          preferred_ip_protocol = "ip4";
        };
      };

      # Resolution of an AdGuard rewrite, answered locally and never forwarded.
      #
      # This is the control in the experiment: it stays green when the upstream
      # path is broken, which is what distinguishes "the internet is
      # unreachable" from "AdGuard is dead". Without it, a failing chain probe
      # cannot tell you which.
      #
      # The answer is asserted, not just the rcode. A rewrite that silently
      # stopped resolving to the right host would otherwise still return NOERROR
      # from the upstream and look fine -- and the whole `.lan` -> TLS migration
      # depends on these rewrites pointing where they claim to.
      dns_internal = {
        prober = "dns";
        timeout = "5s";
        dns = {
          query_name = "sdrhub.lan";
          query_type = "A";
          valid_rcodes = [ "NOERROR" ];
          transport_protocol = "udp";
          preferred_ip_protocol = "ip4";
          # Anchored at both ends of the address, and that is load-bearing.
          # The exporter matches this against each answer RR's string form
          # (`sdrhub.lan.\t60\tIN\tA\t192.168.31.20`), so an unanchored
          # `.*192\.168\.31\.20` is also satisfied by 192.168.31.200 -- a
          # rewrite silently repointed at a different host in the same /24
          # would keep the probe green. `\s` matches the tab that separates
          # the rdata from the type, so the leading `.*` cannot absorb part
          # of the address either.
          validate_answer_rrs = {
            fail_if_not_matches_regexp = [ ".*\\s192\\.168\\.31\\.20$" ];
          };
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

      # The `-secondary` suffix is load-bearing, not cosmetic: the cert-expiry
      # rules in alert-rules/blackbox-alerts.yaml select `job!~".*-secondary"`
      # so a certificate shared with a primary target is reported once rather
      # than once per probed URL. Renaming these jobs without updating those
      # rules would silently restore the duplicate cert alerts.
      (mkProbeJob "blackbox-https-secondary" "https_2xx" publicAppSecondaryEndpoints)
      (mkProbeJob "blackbox-https-redirect-secondary" "https_redirect" publicRedirectSecondaryEndpoints)

      # `-secondary`, because every one of these shares the single
      # int.fredsystems.org wildcard with the authed job below. Without the
      # suffix, one failed renewal of that wildcard would be reported once per
      # probed URL rather than once.
      (mkProbeJob "blackbox-https-internal-secondary" "https_2xx_internal" internalEndpoints)

      # No `-secondary` suffix, deliberately. The cert-expiry rules select
      # `job!~".*-secondary"`, and this job is the only non-secondary probe of
      # the int.fredsystems.org wildcard -- so it is exactly the one target
      # that carries that certificate's expiry alerting, satisfying the
      # one-target-per-certificate invariant those rules need.
      (mkProbeJob "blackbox-https-internal-authed" "https_401" internalTlsAuthedEndpoints)

      # The plaintext -> TLS compatibility layer. No certificate involved, so
      # the `-secondary` question does not arise; probe_ssl_earliest_cert_expiry
      # is simply absent for these.
      (mkProbeJob "blackbox-http-internal-redirect" "http_308" internalRedirectEndpoints)

      # The three DNS probes. Job names are load-bearing: the DnsResolutionFailing
      # rule in alert-rules/blackbox-alerts.yaml selects on `blackbox-dns-.*`,
      # and BlackboxProbeFailed excludes that same pattern so a DNS fault pages
      # once with a useful description rather than twice with a generic one.
      (mkProbeJob "blackbox-dns-chain" "dns_external" dnsChainEndpoints)
      (mkProbeJob "blackbox-dns-upstream" "dns_external" dnsUpstreamEndpoints)
      (mkProbeJob "blackbox-dns-rewrite" "dns_internal" dnsRewriteEndpoints)

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
