{
  lib,
  pkgs,
  stateVersion,
  config,
  ...
}:
let
  inherit (import ../../../modules/services/mk-container-secret.nix)
    mkContainerSecret
    ;

  # Bind addresses for container port publishing.
  #
  # Docker's `-p` defaults to 0.0.0.0, and its DNAT rules are installed in the
  # DOCKER chain, which nftables/iptables evaluates BEFORE nixos-fw. The result
  # was that `networking.firewall.allowedTCPPorts` described a machine that did
  # not exist: the firewall listed 80/443/2269/8078, while every container port
  # -- tar1090, acarshub, imageapi, fredsite, the dozzle agent, and the whole
  # ADS-B feed range -- was in fact reachable from the public internet.
  #
  # That was not theoretical. A confirmed Tor exit node (192.42.116.47,
  # AS215125 "Church of Cyberology") held a 4.2-hour connection to :30005 and
  # pulled 26 MB of Beast data, and a Surfshark VPN endpoint
  # (178.255.41.198) was simultaneously pulling :30005 and browsing the
  # tar1090 UI on :8081. Neither appeared in nginx's access log, because
  # neither went through nginx.
  #
  # Publishing on an explicit address is the fix. nginx reaches the web
  # backends over the loopback, and sdrhub reaches the feed listeners over
  # Tailscale, so nothing legitimate needs a public bind.
  localhost = "127.0.0.1";

  # ---------------------------------------------------------------------
  # THE ONE PLACE TO EDIT IF THIS HOST'S TAILSCALE ADDRESS EVER CHANGES.
  # ---------------------------------------------------------------------
  #
  # Every Tailscale bind on this host -- twelve container port mappings, the
  # Dozzle agent, node_exporter, cAdvisor and the fail2ban exporter -- is
  # derived from this single binding, which is published to the rest of the
  # config as deployment.tailscaleAddress below.
  #
  # A literal is required here, not the MagicDNS name: `docker run -p` rejects
  # a hostname outright ("docker: invalid IP address: ..."), and exporter
  # listen addresses are baked into unit files at build time, before
  # tailscaled exists to resolve anything.
  #
  # Everything that resolves at RUNTIME deliberately does not use this. The
  # feed targets in secrets.yaml and Prometheus's scrapeAddress all use
  # fredvps.tailc21fc7.ts.net, so they follow a re-IP with no edit at all.
  #
  # Tailscale addresses are stable while a node stays registered, but they do
  # change if the node is removed and re-added, reinstalled, or has its disk
  # wiped. The tailscale-address-drift unit (modules/base/deployment-meta.nix)
  # re-runs on every activation, compares this value against the live one, and
  # warns if they diverge -- so a stale entry is reported at deploy time
  # rather than discovered when a container refuses to start.
  tailscaleIP = "100.82.147.29";

  # ---------------------------------------------------------------------
  # DECOY PORTS -- the tripwire set feeding the port-decoy jail.
  # ---------------------------------------------------------------------
  #
  # Nothing on this host listens on any of these, and nothing legitimate has
  # any reason to dial them. That is the entire selection criterion, and it is
  # what makes a single SYN here a zero-false-positive signal: it is a scanner
  # every single time. The firewall already drops these packets; logging them
  # is what puts the knock on the same escalation ladder as everything else.
  #
  # PORT 22 IS DELIBERATELY NOT IN THIS LIST. It keeps its own rule, filter and
  # jail (ssh-decoy, below) rather than being folded in here. fail2ban keys ban
  # escalation on the jail name, so folding 22 into a renamed jail would have
  # discarded its accumulated ban history -- and 22 is by far the most probed
  # port on this host, so that history is the most valuable of the set. The
  # split costs one extra iptables rule and one extra filter thread.
  #
  # Splitting the jails would normally cost detection, because ban counts are
  # per jail: at maxretry = 2 an address knocking once on 22 and once on 3306
  # would sit at 1-of-2 in each and trip neither, which measurement showed was
  # not hypothetical -- 40% of port-22 knockers hit exactly once in 24h, and
  # recidive cannot help since it feeds on Ban lines that were never written.
  #
  # BOTH JAILS THEREFORE RUN maxretry = 1, which closes that gap completely: one
  # knock on any watched port is a ban, so it no longer matters which jail the
  # evidence lands in and the split is purely about preserving history. It also
  # makes detection robust against the rate limiter below -- at maxretry = 2 a
  # dropped LOG line meant a scanner needed two surviving lines to be banned,
  # where now it needs one.
  #
  # The price is that ignoreIP is now the ONLY thing standing between a single
  # stray SYN and a host-wide escalating ban. See the note on that list.
  #
  # ADDING A PORT: the bar is "no legitimate party will ever dial this". Note
  # that the risk is NOT a port this host serves -- an allowed port is
  # ACCEPTed earlier in nixos-fw and never reaches the LOG rule (there is an
  # assertion below enforcing that). The risk is a port some remote party
  # still dials out of habit after we stopped serving it. This host has real
  # history there: :30005 and :7007 were publicly reachable for months and had
  # actual clients, and the home Comcast address had to be added to ignoreIP
  # after a live test banned it. So a formerly-public port is exactly the wrong
  # thing to put in this list, and every entry below is a port this host has
  # never served.
  #
  # DELIBERATELY ABSENT:
  #
  #   - 5555, 4567, 8080-adjacent app ports. 5555 is a classic scan target
  #     (Android ADB) but acars_router publishes it; 4567 is cAdvisor. Ports
  #     in use anywhere on this host stay out even when they are only bound to
  #     the loopback or the tailnet, because the whole point is that this list
  #     needs no cross-checking against anything.
  #   - 3000. Free today, but it is the port a future container is most likely
  #     to want, and a stale decoy entry is worse than a missing one.
  #   - Every UDP port. SSDP (1900), SNMP (161), NTP (123), memcached UDP and
  #     friends are heavily probed, but they are probed for AMPLIFICATION, and
  #     amplification probes carry a SPOOFED source -- the address in the
  #     packet is the intended victim, not the attacker. Banning it would ban
  #     an innocent third party, and our bans are host-wide and escalate to a
  #     week. TCP-SYN-only keeps the "the source address is really the sender"
  #     assumption that the whole ban ladder rests on.
  #   - A blanket "log every refused SYN" rule. That is the logical endpoint of
  #     this reasoning and it was considered, but it converts the curated
  #     zero-false-positive set into an open-ended one: any port this host ever
  #     served, or ever will, becomes a self-ban waiting to happen. The list is
  #     the feature.
  decoyPorts = [
    21 # FTP
    23 # Telnet
    25 # SMTP -- no MTA on this host; open-relay hunting
    110 # POP3
    135 # MS RPC endpoint mapper
    139 # NetBIOS session service
    143 # IMAP
    445 # SMB
    1433 # MSSQL
    1521 # Oracle TNS
    1723 # PPTP
    2375 # Docker API, plaintext -- this host runs Docker, so this one is pointed
    2376 # Docker API, TLS
    3128 # Squid / open-proxy hunting
    3306 # MySQL
    3389 # RDP
    5432 # PostgreSQL
    5900 # VNC
    6379 # Redis
    7547 # TR-069 / CWMP router management
    8080 # HTTP alt -- the first entry to delete if anything ever needs it
    8443 # HTTPS alt
    9200 # Elasticsearch
    11211 # memcached, TCP half only
    27017 # MongoDB
    32764 # Sercomm router backdoor

    # below are ports that we had actors on messing about before, sucking data
    30005

    # 30002 (raw out), 30003 (SBS/BaseStation out) and 30047 have no
    # observed clients at all. Same reasoning: keep the mapping, drop
    # the public exposure.
    30002
    30003
    30047
  ];

  # xt_multiport takes at most 15 ports per rule, so the list is emitted in
  # chunks. Generated rather than hand-written so the port table above stays
  # the single place to edit.
  chunkPorts = xs: if xs == [ ] then [ ] else [ (lib.take 15 xs) ] ++ chunkPorts (lib.drop 15 xs);

  # Appended to nixos-fw ahead of the final log-refuse jump. These only LOG --
  # the packet still falls through to the normal refuse path, so this changes
  # what is recorded, not what is allowed.
  #
  # ON THE RATE LIMIT. An unthrottled LOG on a scanned port is a self-inflicted
  # journal flood, and these rules cover 26 ports rather than one. The burst is
  # sized to the port count on purpose: a scanner sweeping the whole set in one
  # pass produces ~26 lines back to back, and a burst smaller than that would
  # spend the budget on the first few ports and drop the rest, which matters
  # because the budget is shared across all sources.
  #
  # Sustained 30/m is a ceiling that reality stays far below, because the
  # system is self-limiting: fail2ban's action installs its jump with
  # `iptables -I INPUT`, i.e. at position 1, ahead of the jump to nixos-fw. So
  # a banned address is DROPped before it can reach this rule and stops
  # consuming log budget entirely. Steady-state volume therefore tracks the
  # arrival rate of NEW scanning addresses, not how loudly any of them scan.
  #
  # Per-source `-m hashlimit --hashlimit-mode srcip` was considered and
  # rejected: it would give every source its own budget, which is precisely
  # what turns a distributed sweep from thousands of addresses into the journal
  # flood the limit exists to prevent.
  portDecoyLogRules = lib.concatMapStringsSep "\n" (ports: ''
    ip46tables -w -A nixos-fw -p tcp -m multiport --dports ${
      lib.concatMapStringsSep "," toString ports
    } --syn \
      -m limit --limit 30/m --limit-burst 30 \
      -j LOG --log-level info --log-prefix "port-decoy: "
  '') (chunkPorts decoyPorts);

  # Port 22, kept byte-for-byte as it has run in production since c875c196.
  #
  # Deliberately NOT merged into the multiport rules above, and deliberately
  # still on 12/m burst 6. This rule and its jail are the pair whose ban history
  # is being preserved, so the less that changes about them the better: a
  # different prefix would orphan the filter, and a different limit would change
  # the sampling of a signal that has months of continuity behind it.
  #
  # 12/m is ample here despite being far below the port-decoy budget, because
  # this rule watches exactly one port. Measured: 192 distinct addresses knocked
  # on 22 in 24h, ~400 packets/day, i.e. under 0.3/min against a 12/min budget.
  sshDecoyLogRule = ''
    ip46tables -w -A nixos-fw -p tcp --dport 22 --syn \
      -m limit --limit 12/m --limit-burst 6 \
      -j LOG --log-level info --log-prefix "ssh-decoy: "
  '';
in
{
  imports = [
    ./hardware-configuration.nix
    ../../../profiles/adsb-hub.nix
    ../../../modules/services/tailscale
    ../../../modules/services/python-venv-app.nix
    ../../../modules/system/docker-user-firewall.nix
    ./nginx.nix
    ./discord-backup.nix
    ./imageapi-metrics.nix
  ];

  # Tailscale MagicDNS name — fill in your tailnet name, e.g. "fredvps.tail1234.ts.net"
  # Run `tailscale status` after first deploy to confirm the assigned name.
  deployment = {
    scrapeAddress = "fredvps.tailc21fc7.ts.net";

    # The only node in this fleet with a public interface. Everything else
    # sits behind NAT, which is why the monitoring exporters bind 0.0.0.0 and
    # open their own firewall ports by default -- harmless on the LAN, but on
    # this host it published node_exporter (3021 lines of host metrics) and
    # cAdvisor (per-container stats, including every container name)
    # unauthenticated to the internet. Prometheus already scrapes this node
    # over Tailscale, so binding the tailnet address costs nothing.
    internetFacing = true;
    tailscaleAddress = tailscaleIP;
  };

  # The common packages module unconditionally enables systemd-boot and
  # networkmanager; override both since this VPS uses GRUB + systemd-networkd.
  boot = {
    # Boot - GRUB on /dev/sda (VPS, BIOS boot, no EFI)
    loader = {
      systemd-boot.enable = lib.mkForce false;
      efi.canTouchEfiVariables = lib.mkForce false;
      grub = {
        enable = true;
        device = "/dev/sda";
        useOSProber = false;
      };
    };
  };

  system.stateVersion = stateVersion;

  networking = {
    hostName = "fredvps";
    useNetworkd = true;
    useDHCP = false;
    networkmanager.enable = lib.mkForce false;
    # SSH only. 80 and 443 are opened by nginx.nix.
    #
    # 8078 (the flipaholics uvicorn app) used to be here. It is reached
    # exclusively through nginx's proxy_pass on the loopback -- `ss` showed no
    # direct client ever, and the vhost has proxied it the whole time -- so
    # the public opening served nothing but scanners. Removed together with
    # the app's own 0.0.0.0 bind below; re-add both if the app ever needs to
    # be reached without going through nginx.
    firewall = {
      allowedTCPPorts = [
        2269
      ];

      # Catches anything knocking on a closed port that nothing legitimate
      # dials, feeding the ssh-decoy and port-decoy jails. Port table and full
      # rationale are in the let block at the top of this file.
      extraCommands = lib.concatStringsSep "\n" [
        sshDecoyLogRule
        portDecoyLogRules
      ];
    };
  };

  # A decoy port that is also an open port is a silently dead decoy, not a
  # self-ban: nixos-fw ACCEPTs allowed ports well before the appended LOG rules,
  # so the knock is never recorded and the jail simply never fires for it. That
  # failure is invisible in production -- the config still reads as though the
  # port were being watched -- so it fails at eval time instead.
  assertions =
    let
      # 22 is watched by sshDecoyLogRule rather than being in decoyPorts, so it
      # has to be added back here or the guard would have a hole exactly where
      # the most-probed port is.
      watched = decoyPorts ++ [ 22 ];
      clash = lib.intersectLists watched config.networking.firewall.allowedTCPPorts;
    in
    [
      {
        assertion = clash == [ ];
        message =
          "fredvps: decoy ports also declared open, so their LOG rule is unreachable: "
          + lib.concatMapStringsSep ", " toString clash;
      }
    ];

  # Per-IP ban metrics, for the "Active Bans" panel on the security dashboard.
  #
  # WHY node_exporter AND NOT THE FAIL2BAN EXPORTER
  #
  # prometheus-fail2ban-exporter reports only per-JAIL aggregates
  # (f2b_jail_banned_current and friends). It has no per-IP series, so "which
  # addresses are banned and for how long" cannot be answered from it.
  #
  # It does ship a --collector.textfile.directory flag, and that was tried
  # first. It is broken: the exporter gzips its own metrics and then appends
  # the textfile content UNCOMPRESSED, so Prometheus rejects the whole scrape
  # with "gzip: invalid header" and every fail2ban metric disappears. That was
  # observed in production, not inferred.
  #
  # node_exporter's textfile collector is a separate, working implementation
  # that is already enabled fleet-wide and already serving four .prom files on
  # this host, so this follows an established path instead of a novel one.
  #
  # WHY fail2ban-client AND NOT THE SQLITE DATABASE
  #
  # The running daemon holds fail2ban.sqlite3 open; concurrent reads fail with
  # "database is locked". `fail2ban-client get <jail> banip --with-time` is the
  # supported interface and already returns everything needed:
  #
  #   20.199.183.210 <TAB> 2026-08-09 14:23:56 + 3600 = 2026-08-09 15:23:56
  systemd = {
    services.fail2ban-ban-metrics = {
      description = "Write per-IP fail2ban ban metrics for node_exporter";
      after = [ "fail2ban.service" ];
      wants = [ "fail2ban.service" ];

      serviceConfig = {
        Type = "oneshot";
        # Deliberately no sandboxing beyond the default. This needs to talk to
        # the fail2ban socket as root and write into a root-owned directory
        # shared with the other generators, matching how those units are
        # written in modules/monitoring/agent/node_exporter.nix.
        ExecStart = pkgs.writeShellScript "fail2ban-ban-metrics.sh" ''
          set -uo pipefail

          export PATH=${
            lib.makeBinPath [
              pkgs.fail2ban
              pkgs.coreutils
              pkgs.gnused
            ]
          }

          TEXTFILE_DIR=/var/lib/node_exporter/textfiles
          OUT="$TEXTFILE_DIR/fail2ban_bans.prom"
          TMP="$OUT.$$"

          mkdir -p "$TEXTFILE_DIR"

          # Cap per jail. Only CURRENTLY banned addresses are emitted, so this
          # normally sits around ten and expires down on its own -- but a
          # distributed sweep during a 64h escalated bantime could pile up, and
          # unbounded per-IP labels are how a metrics backend gets hurt. Anything
          # past the cap is counted, not emitted.
          MAX_PER_JAIL=200

          {
            echo "# HELP f2b_banned_ip_bantime_seconds Length of the current ban for this address."
            echo "# TYPE f2b_banned_ip_bantime_seconds gauge"
            echo "# HELP f2b_banned_ip_expiry_timestamp_seconds Unix time at which this ban expires."
            echo "# TYPE f2b_banned_ip_expiry_timestamp_seconds gauge"
            echo "# HELP f2b_banned_ip_truncated Banned addresses omitted because the per-jail cap was hit."
            echo "# TYPE f2b_banned_ip_truncated gauge"
            echo "# HELP f2b_ban_metrics_generated_timestamp_seconds Unix time this file was last written."
            echo "# TYPE f2b_ban_metrics_generated_timestamp_seconds gauge"
            echo "# HELP f2b_ban_metrics_fail2ban_up Whether the jail list could be read from fail2ban."
            echo "# TYPE f2b_ban_metrics_fail2ban_up gauge"
            echo "# HELP f2b_ban_metrics_parse_failures Lines from fail2ban-client that did not parse."
            echo "# TYPE f2b_ban_metrics_parse_failures gauge"
            echo "# HELP f2b_ban_metrics_jail_query_failures Jails whose ban list could not be read."
            echo "# TYPE f2b_ban_metrics_jail_query_failures gauge"
            echo "# HELP f2b_banned_ip_max_bantime_seconds Longest ban in force in this jail, including addresses omitted by the cap."
            echo "# TYPE f2b_banned_ip_max_bantime_seconds gauge"

            # Health, kept separate from freshness on purpose.
            #
            # The timestamp below is written unconditionally, so a failed query
            # still produces a fresh file rather than a stale one. That alone
            # would make "fail2ban is down" look identical to "nobody is
            # banned" -- both render as an empty table with a green age panel,
            # and the down case is the one worth paging on. This flag is what
            # separates them.
            if jails=$(fail2ban-client status 2>/dev/null \
              | sed -n 's/.*Jail list:[[:space:]]*//p' \
              | tr -d ' ' | tr ',' ' '); then
              echo "f2b_ban_metrics_fail2ban_up 1"
            else
              jails=""
              echo "f2b_ban_metrics_fail2ban_up 0"
            fi

            parse_failures=0
            jail_query_failures=0

            for jail in $jails; do
              n=0
              omitted=0
              max_bantime=0

              # Captured into a variable rather than piped directly into the
              # loop so the exit status is observable. Previously this ended
              # in `|| true`, which turned a failed query into an empty result:
              # the jail silently contributed no bans while fail2ban_up stayed
              # 1 and the timestamp stayed fresh, so every health signal read
              # green with data missing. A per-jail failure is distinct from
              # the daemon being unreachable, so it gets its own counter
              # rather than clearing fail2ban_up.
              if ! banlist=$(fail2ban-client get "$jail" banip --with-time 2>/dev/null); then
                jail_query_failures=$((jail_query_failures + 1))
                printf 'f2b_banned_ip_truncated{jail="%s"} 0\n' "$jail"
                printf 'f2b_banned_ip_max_bantime_seconds{jail="%s"} 0\n' "$jail"
                continue
              fi

              # Output line: <ip> \t <start> + <bantime> = <expiry>
              while IFS= read -r line; do
                [ -z "$line" ] && continue

                ip=''${line%%[[:space:]]*}
                bantime=$(printf '%s' "$line" | sed -n 's/.* + \([0-9][0-9]*\) = .*/\1/p')
                expiry=$(printf '%s' "$line" | sed -n 's/.* = //p')

                # A non-empty line that does not parse means the output format
                # drifted. Counted rather than skipped silently, since the
                # symptom would otherwise be an empty table that looks healthy.
                if [ -z "$ip" ] || [ -z "$bantime" ] || [ -z "$expiry" ]; then
                  parse_failures=$((parse_failures + 1))
                  continue
                fi

                if ! epoch=$(date -d "$expiry" +%s 2>/dev/null); then
                  parse_failures=$((parse_failures + 1))
                  continue
                fi

                # Tracked before the cap, so the aggregate stays correct even
                # when per-IP series are dropped.
                #
                # `banip --with-time` returns bans sorted ascending by EXPIRY
                # (banmanager.py getBanList -> lst.sort on end-of-ban), and
                # expiry order is not bantime order -- a fresh 1h ban expires
                # before an older 2h one. So the cap removes an arbitrary
                # slice with respect to duration, and max() over the emitted
                # series alone can under-report the longest ban in force.
                # Which is exactly the number the "Longest Active Ban" panel
                # exists to show, and exactly when it matters: a sweep large
                # enough to hit the cap.
                if [ "$bantime" -gt "$max_bantime" ]; then
                  max_bantime=$bantime
                fi

                n=$((n + 1))
                if [ "$n" -gt "$MAX_PER_JAIL" ]; then
                  omitted=$((omitted + 1))
                  continue
                fi

                # ban_id exists so the dashboard can join the two series on a
                # key that is actually unique. An address in two jails at once
                # is routine here -- the three nginx jails read the same log --
                # and joining on ip alone pairs the wrong ban length with the
                # wrong jail, producing a plausible-looking wrong row.
                printf 'f2b_banned_ip_bantime_seconds{jail="%s",ip="%s",ban_id="%s:%s"} %s\n' \
                  "$jail" "$ip" "$jail" "$ip" "$bantime"
                printf 'f2b_banned_ip_expiry_timestamp_seconds{jail="%s",ip="%s",ban_id="%s:%s"} %s\n' \
                  "$jail" "$ip" "$jail" "$ip" "$epoch"
              done <<< "$banlist"

              printf 'f2b_banned_ip_truncated{jail="%s"} %s\n' "$jail" "$omitted"
              printf 'f2b_banned_ip_max_bantime_seconds{jail="%s"} %s\n' "$jail" "$max_bantime"
            done

            printf 'f2b_ban_metrics_parse_failures %s\n' "$parse_failures"
            printf 'f2b_ban_metrics_jail_query_failures %s\n' "$jail_query_failures"

            # Freshness. If this stops advancing the panel is showing stale data,
            # which is otherwise indistinguishable from "nobody is banned".
            printf 'f2b_ban_metrics_generated_timestamp_seconds %s\n' "$(date +%s)"
          } > "$TMP"

          # Atomic replace: node_exporter reads this directory on every scrape
          # and must never see a partially written file.
          mv "$TMP" "$OUT"
        '';
      };
    };

    timers.fail2ban-ban-metrics = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Every 2 minutes. The other textfile generators run at 10, but this one
        # backs a live countdown, and each run is two socket round-trips to the
        # local fail2ban daemon.
        OnBootSec = "2min";
        OnUnitActiveSec = "2min";
        AccuracySec = "10s";
      };
    };
  };

  # Filter backing the nginx-probe jail above. Matches the 444 that the
  # $blocked_probe map in nginx.nix returns for credential-theft and
  # WordPress/PHP scans.
  #
  # 444 is nginx's "close the connection without a response", which never
  # reaches the wire as a status code -- it only ever appears in our own
  # access log, written by our own rule. That makes it an unambiguous marker
  # for "this request was a probe", unlike 404 or 403 which legitimate traffic
  # also produces here in volume.
  environment.etc = {
    "fail2ban/filter.d/nginx-probe.conf".text = ''
      [Definition]
      # `.*` between the host and the request rather than an explicit
      # `\S+ \S+ \[timestamp\]`: fail2ban extracts the timestamp with
      # datepattern and hands the failregex a line with that section already
      # substituted, so a regex that tries to match the literal
      # "- - [09/Aug/2026:01:34:08 -0600]" never fires. That was verified the
      # hard way -- the stricter pattern matched 0 of 94 real 444 lines.
      #
      # The trailing \s keeps this anchored to the status field so it cannot
      # match a 444 appearing anywhere else in the line, e.g. in a URL or a
      # user agent.
      failregex = ^<HOST> .* "[A-Z]+ [^"]*" 444\s
      ignoreregex =
      datepattern = ^[^\[]*\[({DATE})
                    {^LN-BEG}
    '';

    # Host-wide, silent bans.
    #
    # Two deviations from the stock `iptables-multiport` + REJECT default,
    # both deliberate.
    #
    # ALLPORTS, NOT MULTIPORT. The stock action installs the jump into INPUT
    # as `-p tcp -m multiport --dports http,https -j f2b-nginx-probe`, so a
    # prober banned by an nginx jail was still free to hit sshd on 2269. Note
    # that this is NOT visible in `iptables -L f2b-nginx-probe`: the per-
    # address rules in that chain always read `all -- <ip> 0.0.0.0/0`, because
    # the port match lives on the INPUT jump rule, not on the ban rules. The
    # chain listing looks host-wide under both actions; `iptables -L INPUT -n`
    # is where the difference actually shows. `type = allports` drops the port
    # match from the jump, which makes the "all" in the chain listing mean
    # what it appears to.
    #
    # DROP, NOT REJECT. The default answers with ICMP port-unreachable, which
    # tells a scanner immediately that it is blocked and frees it to move on.
    # DROP makes it wait for its own TCP timeout on every connection, and
    # since our bans are host-wide that cost applies to every port it tries.
    #
    # blocktype is set for both families -- iptables.conf overrides it under
    # [Init?family=inet6] for the ICMPv6 variant, so setting only the v4 value
    # would leave IPv6 offenders on REJECT.
    "fail2ban/action.d/iptables-allports-drop.conf".text = ''
      [INCLUDES]
      before = iptables.conf

      [Definition]
      type = allports

      [Init]
      blocktype = DROP

      [Init?family=inet6]
      blocktype = DROP
    '';

    # Filter for the decoy LOG rules (networking.firewall.extraCommands).
    #
    # Anchored on the log prefix, which is ours alone and is what keeps this
    # from matching any other kernel LOG line -- notably
    # `logRefusedConnections`, if that is ever turned on, which uses the same
    # field layout with a different prefix.
    #
    # The port is deliberately NOT enumerated here. This filter previously
    # pinned `DPT=22` as a second anchor, which was free when the rule watched
    # exactly one port; carrying that forward would mean restating all 27 ports
    # as a regex alternation that has to be kept in step with the Nix list, and
    # a drift between the two fails open (the port gets logged and never
    # banned). `DPT=` is still required so the line has to be the transport-
    # layer shape the rule produces, but which port it was is the iptables
    # rule's business, not the filter's.
    #
    # journalmatch IS A SECURITY CONTROL HERE, NOT AN OPTIMISATION.
    #
    # This jail runs on the systemd backend, and with no match restriction that
    # backend reads the ENTIRE journal, not just kernel messages. Any process
    # that can get attacker-controlled text into the journal can therefore
    # forge a decoy hit, and <HOST> binds to whatever follows SRC= in the
    # forged text -- which is an arbitrary-IP ban primitive, not merely a false
    # positive. sshd is a live path to it: usernames are attacker-supplied and
    # are logged verbatim, so
    #
    #   ssh -p 2269 'port-decoy: SRC=8.8.8.8 DPT=443 x'@fredvps
    #
    # yields `Invalid user port-decoy: SRC=8.8.8.8 DPT=443 x from ...`, and two
    # of those get 8.8.8.8 banned host-wide on an escalating ladder that tops
    # out at a week. Verified with fail2ban-regex, which extracted 8.8.8.8 from
    # exactly that line. Restricting the jail to _TRANSPORT=kernel closes it:
    # that field is set by journald from the message's origin and no userspace
    # writer can claim it.
    #
    # This is also why the failregex below does not need to enumerate ports to
    # be safe. Provenance is what makes the line trustworthy, and provenance is
    # enforced here rather than guessed at from the message text.
    "fail2ban/filter.d/port-decoy.conf".text = ''
      [Definition]
      failregex = ^.*\bport-decoy:\s.*\bSRC=<HOST>\b.*\bDPT=\d+\b
      ignoreregex =
      journalmatch = _TRANSPORT=kernel
    '';

    # Port 22's filter, unchanged except for journalmatch.
    #
    # Still anchored on DPT=22 as well as the prefix. That is not redundant here
    # the way it would be for port-decoy: it is what keeps this jail's evidence
    # disjoint from the other rule's, so the two ban ladders stay independent.
    #
    # journalmatch is the same security control described above and matters just
    # as much here -- more, in fact, since the sshd log lines that provide the
    # injection vector arrive on the very port this filter watches.
    "fail2ban/filter.d/ssh-decoy.conf".text = ''
      [Definition]
      failregex = ^.*\bssh-decoy:\s.*\bSRC=<HOST>\b.*\bDPT=22\b
      ignoreregex =
      journalmatch = _TRANSPORT=kernel
    '';
  };

  # Backstop for the Docker/nixos-fw gap described at the top of this file.
  # Every container port is now published on an explicit bind address, so in
  # the current configuration this chain should never actually drop a packet.
  # It exists so that the next container added here fails closed if its port
  # mapping omits the bind address, instead of silently reappearing on the
  # public internet the way :30005 and :7007 did.
  dockerUserFirewall = {
    enable = true;
    externalInterface = "enp1s0";
    # Deliberately empty: nothing published by a container on this host is
    # meant to be publicly reachable. nginx is not a container and is
    # unaffected -- it binds the host directly on 80/443 via nixos-fw.
    allowedTCPPorts = [ ];
  };

  systemd.network = {
    enable = true;
    networks."10-wan" = {
      matchConfig.Name = "enp1s0";
      networkConfig = {
        DHCP = "ipv4";
        IPv6AcceptRA = false;
      };
      address = [
        "2a01:4ff:f0:2bab::/64"
      ];
      routes = [
        { Gateway = "fe80::1"; }
      ];
    };
  };

  system.activationScripts.adsbDockerCompose = {
    text = ''
      # Ensure directory exists (does not touch contents if already there)
      install -d -m0755 -o fred -g users /opt/adsb
      install -d -m0755 -o fred -g users /opt/adsb/imageapi
      install -d m0755 -o fred -g users /opt/adsb/imageapi/data/
    '';
    deps = [ ];
  };

  sops.secrets = {
    "docker/fredvps/tar1090.env" = mkContainerSecret "tar1090";

    "docker/fredvps/acars_router.env" = mkContainerSecret "acars_router";

    "docker/fredvps/acarshub.env" = mkContainerSecret "acarshub";

    "docker/fredvps/fredsite.env" = mkContainerSecret "fredsite";

    "github_api" = {
      mode = "0444";
    };
  };

  services = {
    openssh.ports = [ 2269 ];

    # Accept subnet routes advertised by sdrhub (192.168.31.0/24) so that
    # LAN services (Attic, Loki, etc.) are reachable without config changes.
    tailscale.extraUpFlags = [ "--accept-routes" ];

    # Ban/jail metrics for Prometheus, so the security dashboard shows live
    # state rather than requiring an ssh + `fail2ban-client status` per jail.
    #
    # Bound to the tailnet for the same reason as node_exporter and cAdvisor:
    # this host faces the internet, and the exporter would otherwise publish
    # jail names and banned-IP counts to anyone who asked. Reusing
    # deployment.tailscaleAddress keeps that decision in one place.
    prometheus.exporters.fail2ban = {
      enable = true;
      # `host`, NOT `listenAddress`. Both options exist on this exporter --
      # listenAddress comes from the shared exporter boilerplate -- but only
      # `host` is interpolated into --web.listen-address. Setting
      # listenAddress alone is silently ignored and leaves the exporter on
      # 127.0.0.1, where Prometheus cannot reach it, while the config reads as
      # though it were bound to the tailnet.
      host = tailscaleIP;
      port = 9191;
      # No openFirewall: Prometheus reaches this over Tailscale, which does
      # not traverse nixos-fw's port rules.
      openFirewall = false;
    };

    fail2ban = {
      enable = true;
      maxretry = 5;
      bantime = "1h";

      # Host-wide silent bans for every jail. See the action definition above
      # for why allports and why DROP. Both are set because banaction-allports
      # is what the recidive jail below uses.
      banaction = "iptables-allports-drop";
      banaction-allports = "iptables-allports-drop";

      # How long ban history is retained, which is what the escalation above
      # counts against. The stock value is 1d, so an address that stays away
      # for a day has its ban count purged and starts again at 1h -- and the
      # scanners hitting this host reappear on roughly that cadence, which
      # would have defeated the escalation even after fixing the multipliers.
      #
      # 30d means a persistent scanner keeps climbing the ladder across weeks
      # instead of resetting daily. Cost is a slightly larger sqlite file;
      # it was 200 KB holding 113 bans, so a month of history is negligible.
      daemonSettings.Definition.dbpurgeage = "30d";
      # Escalating bans for repeat offenders.
      #
      # `multipliers` is a SEQUENCE indexed by ban count, not a factor. It was
      # previously "2", a one-element list, and fail2ban reuses the last
      # element once the ban count exceeds the list length -- so every ban
      # after the first was multiplied by exactly 2 and the duration flatlined
      # at 2h regardless of maxtime.
      #
      # Observed on 34.44.183.157 before this change:
      #
      #   ban 1  3600s      ban 4  7200s   (should have been 28800)
      #   ban 2  7200s      ban 5  7200s   (should have been 57600)
      #   ban 3  7200s
      #
      # That mattered practically: the same addresses reappeared roughly every
      # three hours, so a 2h ban had already expired by the time they came
      # back and the escalation never bit. 161 bans against 100 unbans in 48
      # hours, with single addresses banned up to five times.
      #
      # Ladder: 1h, 2h, 4h, 8h, 16h, 32h, 64h, 128h, then 168h from the ninth
      # offence on, where maxtime clamps 256h down to the week.
      #
      # The two trailing entries are what make maxtime load-bearing. Ending
      # the sequence at 64 topped the ladder out at 64h, so `min(ban, maxtime)`
      # never bound and `maxtime = 168h` was decorative -- it described a
      # ceiling the ladder could not reach. 128 is still under the cap; 256 is
      # the first step that exceeds it and therefore the first one maxtime
      # actually clamps.
      #
      # The leading 1 is never evaluated (fail2ban skips the formula entirely
      # on the first ban) but is load-bearing as index padding: the lookup is
      # multipliers[banCount], so removing it shifts every later step down one.
      bantime-increment = {
        enable = true;
        multipliers = "1 2 4 8 16 32 64 128 256";
        maxtime = "168h";
      };

      # Never ban ourselves off the box.
      #
      # Loopback and the tailnet, so a misfiring filter cannot cut the
      # Tailscale management path or ban sdrhub's monitoring, which probes
      # every vhost on a schedule.
      #
      # 73.26.160.99 is the home Comcast address. It is listed because a live
      # test of the nginx-probe jail banned it within seconds -- three
      # deliberate requests to /.env from a workstation behind that address
      # were enough. The ADS-B feeds themselves now run over Tailscale and
      # were unaffected, but a ban still blocks ordinary HTTPS access to every
      # vhost from home, which is a self-inflicted outage for the exact
      # behaviour someone debugging this host is most likely to produce.
      #
      # This is a dynamic address, so it will eventually go stale. THAT DOES
      # NOT FAIL SAFE, in either direction, and this comment previously claimed
      # it did.
      #
      # If Comcast moves us, the entry stops protecting the address we actually
      # use and any jail can then ban home. If Comcast hands 73.26.160.99 to
      # someone else, the entry whitelists a stranger across EVERY jail here --
      # sshd, nginx-probe, nginx-bad-request, recidive. The second case is the
      # nastier one, because nothing about it is visible from this host.
      #
      # The reason this was load-bearing rather than theoretical: a Synology
      # task ("Backup VPS", daily 04:00 NAS-local) ran
      #   rsync -av --delete root@fredclausen.com:/home/fred /volume1/vps
      # with no port override, so it SYNed port 22 every single morning and was
      # ignored only because of this entry. The NAS clock reads an hour behind
      # (a non-DST timezone), which is why it landed at 05:00 in the journal.
      # It had never worked against this host -- sshd has been on 2269 the whole
      # time, and root login is refused regardless -- so it was deleted rather
      # than repaired. Confirmed by rsync exit 255 on its last run.
      #
      # With that gone, nothing at home dials a decoy port on a schedule any
      # more, so a stale entry can no longer produce a self-ban on a timer that
      # escalates 1h -> 2h -> 4h unattended. The residual exposure is
      # interactive only, which is recoverable because a human is present when
      # it happens.
      #
      # THE DECOY JAILS RUN maxretry = 1, so this list is not a safety net any
      # more -- it is the only guard. A single stray SYN to any of the 27
      # watched ports from an address that is not listed here is an immediate
      # host-wide ban, and the ban escalates on repeat. Staleness here is
      # therefore a live outage risk rather than a latent one, which is why the
      # address is monitored for drift rather than merely written down.
      #
      # The address itself comes from shared.homePublicIPv4
      # (modules/data/home-network.nix) rather than being a literal here,
      # because sdrhub's drift check has to compare against the same value. Two
      # independent copies would fail in the worst possible way: the monitor
      # reporting "no drift" against its own stale copy while this list no
      # longer matches the address that is actually arriving.
      #
      # Anything added here in future needs the same test applied: not "is this
      # address mine today" but "what dials this host from it unattended, and
      # what happens the morning after the address changes".
      ignoreIP = [
        "127.0.0.1/8"
        "::1"
        "100.64.0.0/10"
        config.shared.homePublicIPv4
        "209.40.70.5"
      ];

      jails = {
        sshd.settings = {
          enabled = true;
          port = "2269";
          filter = "sshd";
          maxretry = 2;
          mode = "aggressive";
        };

        # Anything that SYNs port 22.
        #
        # sshd is on 2269, so there is no legitimate traffic to 22 on this
        # host and no false-positive surface at all -- one knock is already
        # proof of a scan, which is why maxretry is 1 and not 2. A single
        # retransmitted SYN logging twice is harmless when one is enough.
        #
        # KEPT AS ITS OWN JAIL rather than folded into port-decoy below, purely
        # to preserve its ban history: fail2ban keys escalation on the jail
        # name, so a rename would reset every offender to step 1 of the ladder.
        # 22 is the most-probed port on this host -- 192 distinct addresses in
        # 24h -- so its history is the most valuable of the set. At maxretry = 1
        # the split costs no detection; see the let block at the top of this
        # file.
        #
        # findtime is deliberately long. Slow scanners spread a sweep over
        # hours specifically to stay under short windows, and since the signal
        # here is unambiguous there is no reason to give them that.
        #
        # backend/logpath are inherited from DEFAULT (systemd), which is
        # correct: these lines come from the kernel via the journal.
        ssh-decoy.settings = {
          enabled = true;
          filter = "ssh-decoy";
          maxretry = 1;
          findtime = "1d";
        };

        # The same tripwire for the other 26 ports. Identical settings on
        # purpose -- the signal is identical, only the port set differs, and
        # the split exists for history preservation rather than for any
        # behavioural reason. maxretry must stay in step with ssh-decoy above;
        # if these two ever diverge, the same port knock means different things
        # depending on which rule logged it.
        #
        # New jail, so it starts with an empty ban history and builds its own
        # ladder. Nothing external keys on the name: the ban-metrics generator
        # above enumerates jails from `fail2ban-client status`, and the security
        # dashboard reads the jail as a label rather than filtering on a
        # literal, so both pick this up with no change.
        port-decoy.settings = {
          enabled = true;
          filter = "port-decoy";
          maxretry = 1;
          findtime = "1d";
        };

        # Escalation across jails, which is the part per-jail bans cannot do.
        #
        # Ban counts are tracked per jail, so an address that trips
        # nginx-probe once, nginx-bad-request once and port-decoy once is on
        # step 1 of three separate ladders and never escalates, despite being
        # obviously hostile. This jail reads fail2ban's own Ban lines and
        # treats "banned anywhere, 3 times in a week" as its own offence.
        #
        # It cannot feed itself: the stock filter's failregex carries a
        # `(?!recidive\])` guard, so recidive's own Ban lines are skipped.
        # Verified with fail2ban-regex, not assumed.
        #
        # No logpath. Upstream's jail.conf points this at
        # /var/log/fail2ban.log, which does not exist here -- NixOS sets
        # `logtarget = SYSLOG`, so the daemon's own log only reaches the
        # journal. Inheriting the systemd backend from DEFAULT is what makes
        # this work, and setting a logpath would break it.
        recidive.settings = {
          enabled = true;
          filter = "recidive";
          maxretry = 3;
          findtime = "1w";
          bantime = "1w";
        };

        # Exploit probes, keyed on the 444s produced by the nginx map.
        #
        # The stock nginx-botsearch filter is deliberately NOT used: its
        # failregex matches status 404, and on this host 404 is overwhelmingly
        # legitimate. Real clients generate thousands of them against
        # /api/price_data for items that are simply not in the database --
        # 105.159.200.113 alone produced hundreds. Banning on 404 here would
        # ban customers. 444 is only ever emitted by our own probe rule, so it
        # is an exact signal with no false-positive surface.
        nginx-probe.settings = {
          enabled = true;
          filter = "nginx-probe";
          port = "http,https";
          logpath = "/var/log/nginx/access.log";
          backend = "auto";
          maxretry = 3;
          findtime = "10m";
        };

        # Clients that sustain enough traffic to trip limit_req. Tolerant on
        # purpose: tripping the limiter once is a burst, doing it ten times in
        # ten minutes is a runaway or a scraper.
        nginx-limit-req.settings = {
          enabled = true;
          filter = "nginx-limit-req";
          port = "http,https";
          logpath = "/var/log/nginx/error.log";
          backend = "auto";
          maxretry = 10;
          findtime = "10m";
        };

        # Malformed requests -- protocol garbage and oversized headers. 2241
        # of these in the current log.
        nginx-bad-request.settings = {
          enabled = true;
          filter = "nginx-bad-request";
          port = "http,https";
          logpath = "/var/log/nginx/access.log";
          backend = "auto";
          maxretry = 10;
          findtime = "10m";
        };
      };
    };

    ###################################################################
    # Python venv services — code is manually `git clone`d to
    # /home/nik/<app>, dependencies are pinned in each app's
    # requirements.txt far behind what nixpkgs ships, so pip (not
    # nixpkgs) resolves them into a venv scoped to that directory.
    # See modules/services/python-venv-app.nix.
    ###################################################################
    pythonVenvApps = {
      test-site = {
        path = "/home/nik/test_site";
        user = "nik";
        # Reads the shared database at /mnt/discord. main_db.py prefers
        # app/database/discord_db.sqlite but that exact filename does not
        # exist (the local file is discord_db_TEST.sqlite), so the /mnt
        # fallback is the path actually used. Listed even though this app
        # only reads: SQLite needs to create -wal/-shm alongside the
        # database file, which is a write to the directory.
        extraWritablePaths = [ "/mnt/discord" ];
        # scipy==1.10.1 (pinned in requirements.txt) has no cp312+ wheel.
        python = pkgs.python311;
        # --no-access-log: uvicorn's per-request log was 248780 of this unit's
        # 373819 journal lines over two days (67%), making it the single
        # largest log producer on the host by a wide margin. It is also pure
        # duplication -- nginx already records every one of these requests in
        # /var/log/nginx/access.log (1.3M entries in the current file), and
        # `ss` confirms nothing reaches :8078 except via the flipaholics.pro
        # proxy_pass, so dropping it loses no coverage. Revisit if :8078 is
        # ever exposed directly, since then nginx would no longer see
        # everything.
        # --host 127.0.0.1: nginx proxies this on the loopback, so binding
        # 0.0.0.0 only ever exposed it to the internet. Belt and braces with
        # the firewall change above -- the bind is the real control, since a
        # firewall rule is one edit away from being reopened by accident.
        execStart = "$VENV/bin/uvicorn app.main:app --host 127.0.0.1 --port 8078 --workers 2 --no-access-log";
      };

      discord-bot = {
        path = "/home/nik/discord-bot";
        user = "nik";
        # The live 729 MB database, with 22 write sites in main-discord.py.
        # Confirmed open by the running process, not inferred from source.
        extraWritablePaths = [ "/mnt/discord" ];
        # matplotlib==3.7.5 (pinned in requirements.txt) has no cp313 wheel.
        python = pkgs.python312;
        execStart = "$VENV/bin/python main-discord.py";
      };
    };

    adsb.containers = [
      ###############################################################
      # Fred Site
      ###############################################################
      {
        name = "fredsite";
        image = "ghcr.io/fredsystems/fred-site:latest-build-8@sha256:53659b897364c139dc504e6824ae999febdfe96616fbf306b8681a493510ed81";

        environmentFiles = [
          config.sops.secrets."docker/fredvps/fredsite.env".path
        ];

        # Proxied by nginx at fredclausen.com/. Loopback only.
        ports = [ "${localhost}:4200:80" ];
      }
      ###############################################################
      # DOZZLE AGENT
      ###############################################################
      # Tailscale-only. This agent mounts docker.sock, and Dozzle's agent
      # certificate is shared across all Dozzle images rather than being a
      # per-deployment secret, so a publicly reachable :7007 let anyone point
      # their own Dozzle at this host and read every container's logs --
      # including anything secret-bearing that gets logged. sdrhub is the only
      # consumer and is on the tailnet.
      (import ../../../modules/services/mk-dozzle-agent.nix {
        port = "${tailscaleIP}:7007:7007";
      })

      ###############################################################
      # IMAGE API
      ###############################################################
      {
        name = "imageapi";
        image = "ghcr.io/sdr-enthusiasts/sdre-image-api:latest-build-7@sha256:38df445fe37101648032e849a477ee3221ce8517cebd72983e21d9e1ba8dfbff";

        volumes = [
          "/opt/adsb/imageapi/data:/opt/api"
          "${config.sops.secrets.github_api.path}:/opt/api/sdre-e-updater.2024-02-05.private-key.pem:ro"
        ];

        # Proxied by nginx at /imageapi/. Loopback only.
        ports = [ "${localhost}:3001:3000" ];
      }

      ###############################################################
      # tar1090
      ###############################################################
      {
        name = "tar1090";
        image = "ghcr.io/sdr-enthusiasts/docker-tar1090:telegraf-build-1471@sha256:45c6e52b2c31ef44fbeb69f63ebe317642f5fb2c32277cd8a63abd537236111a";

        environmentFiles = [
          config.sops.secrets."docker/fredvps/tar1090.env".path
        ];

        volumes = [
          "/opt/adsb/tar1090/heatmap:/var/globe_history"
          "/opt/adsb/tar1090/timelapse:/var/timelapse1090"
          "/opt/adsb/tar1090/graphs_1090:/var/lib/collectd"
          "/proc/diskstats:/proc/diskstats:ro"
        ];

        ports = [
          # Web UI: proxied at /tar1090/, so loopback is all nginx needs.
          "${localhost}:8081:80"

          # 30004 (beast_in) and 12000 (sbs_out_jaero) are the only feed ports
          # sdrhub's ultrafeeder actually dials, so they move to Tailscale.
          "${tailscaleIP}:30004:30004"
          "${tailscaleIP}:12000:12000"

          # 30005 is readsb's Beast *output*. It had no authorised consumer --
          # the only two clients were the Tor exit and the Surfshark endpoint
          # described above, both of which had simply found an open port.
          # Bound to Tailscale rather than deleted so it stays available to the
          # fleet, since removing the mapping outright would make a future
          # legitimate consumer look like a container misconfiguration.
          "${tailscaleIP}:30005:30005"

          # 30002 (raw out), 30003 (SBS/BaseStation out) and 30047 have no
          # observed clients at all. Same reasoning: keep the mapping, drop
          # the public exposure.
          "${tailscaleIP}:30002:30002"
          "${tailscaleIP}:30003:30003"
          "${tailscaleIP}:30047:30047"
        ];
      }

      ###############################################################
      # acars_router
      ###############################################################
      {
        name = "acars_router";
        image = "ghcr.io/sdr-enthusiasts/acars_router:latest-build-587@sha256:de236bc97c84e34679d2d0086524d9ebe2dc2252ed47799916a04e19578e4a67";

        environmentFiles = [
          config.sops.secrets."docker/fredvps/acars_router.env".path
        ];

        ports = [
          # sdrhub's acars_router pushes ACARS/VDLM2/HFDL into these three.
          # They are the only feed listeners with a real client, and that
          # client is on the tailnet.
          #
          # These were also the noisiest public ports: 1311 connection
          # attempts over seven days from 183 unique addresses on 5555 alone,
          # 297 of which reset immediately -- port sweeps, not feeders. Only
          # sdrhub ever held an established connection.
          "${tailscaleIP}:5550:5550"
          "${tailscaleIP}:5555:5555"
          "${tailscaleIP}:5556:5556"

          # Secondary listeners with no observed client on this host.
          "${tailscaleIP}:15550:15550"
          "${tailscaleIP}:15555:15555"
          "${tailscaleIP}:15556:15556"
          "${tailscaleIP}:35556:35556"
        ];
      }

      ###############################################################
      # ACARS Hub
      ###############################################################
      {
        name = "acarshub";
        image = "ghcr.io/sdr-enthusiasts/docker-acarshub:latest-build-1509@sha256:5a4967a1c5520bbcf796afa664a05344657b918c2b254626ba9fd7bcfbf7fcb2";

        environmentFiles = [
          config.sops.secrets."docker/fredvps/acarshub.env".path
        ];

        volumes = [
          "/opt/adsb/acarshub:/run/acars"
        ];

        ports = [
          # 8085 is proxied by nginx at /acarshub/ and at acarshub.app.
          # 8888 is the backend API, which the UI reaches in-container; it
          # had no external client and was answering unauthenticated version
          # banners to anyone who asked.
          "${localhost}:8085:80"
          "${localhost}:8888:8888"
        ];
      }
    ];
  };
}
