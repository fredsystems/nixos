{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.deployment;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
in
{
  options.deployment = {
    role = lib.mkOption {
      type = lib.types.str;
      default = "standalone";
      description = "Deployment role for this node (standalone | monitoring-agent | monitoring-master).";
    };

    scrapeAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Hostname or IP address Prometheus uses to scrape this node.
        When null, defaults to "<attr>.local", where <attr> is this host's
        nixosConfigurations attribute name in flake.nix -- NOT
        config.networking.hostName, which is not guaranteed to match (suitable
        for LAN nodes).
        Set this to a Tailscale MagicDNS name for nodes not on the LAN.
      '';
    };

    internetFacing = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether this node has an interface reachable from the public
        internet.

        Every host in this fleet except fredvps sits behind NAT on the LAN,
        so the monitoring exporters bind 0.0.0.0 and open their ports
        unconditionally -- which is harmless there and reachable only from
        the LAN. On a VPS that same configuration publishes them to the
        world: node_exporter served 3021 lines of host metrics and cAdvisor
        served per-container stats, both unauthenticated, to anyone who
        asked.

        Setting this to true makes the exporters bind the Tailscale address
        instead, and stops them opening a firewall port. Prometheus already
        scrapes such nodes over Tailscale (see scrapeAddress), so nothing
        legitimate is lost.

        Requires tailscaleAddress to be set.
      '';
    };

    criticalUnits = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = lib.literalExpression ''
        {
          "atticd.service" = "the binary cache every other node substitutes from";
        }
      '';
      description = ''
        systemd units on this node that must not be bounced as a side effect
        of a routine deploy. Keys are unit names; values are the reason,
        which is what the deploy guard (scripts/lib/deploy-guard.sh) prints when it holds
        the node back.

        ## What this changes

        colmena-apply-drifted.sh compares each listed unit's unit-file store
        path on the running node against the one the target closure
        evaluates to. A change there is exactly what makes
        switch-to-configuration restart the unit, so it is a decision rather
        than a guess. Any node with such a change is deployed with the
        `boot` goal -- closure staged and bootloader updated, nothing
        activated -- instead of `switch`, and the restart happens at a
        reboot you choose (`--reboot`) rather than mid-run.

        ## Why it is declared here and not in the script

        The hazard is fleet-wide, not host-local, and both known instances
        are single points of failure for OTHER nodes' deploys:

          * atticd is the binary cache. Restarting it while colmena is
            substituting closures for seven other nodes fails those builds.
          * AdGuard/Unbound are the LAN's DNS. Restarting them mid-run
            breaks name resolution for every subsequent SSH the deploy makes.

        Naming the hosts in the script would encode where those services
        happen to live today. Declaring it next to the service definition
        means moving atticd to another host moves the protection with it,
        with no script edit and nothing to forget.

        ## Scope

        Linux only -- the assertion below and the whole mechanism are
        systemd-specific, and this module is also imported on Darwin.
      '';
    };

    criticalProcesses = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { config, ... }:
          {
            options = {
              package = lib.mkOption {
                type = lib.types.package;
                description = "The package whose binary the running process is expected to come from.";
              };

              pnames = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ config.package.pname ];
                defaultText = lib.literalExpression "[ package.pname ]";
                description = ''
                  Package names (the `pname` half of a store path's
                  `pname-version`, split the way builtins.parseDrvName splits
                  it) that identify a running instance of this process.

                  A process is attributed to a package by the store path of
                  its binary -- /proc/<pid>/exe, or argv[0] when exe cannot be
                  read -- not by its name. Process names are unreliable here:
                  the kernel's `comm` is truncated to 15 bytes and reads
                  `.Hyprland-wrapp` for a wrapped binary, and Electron apps
                  run out of opt/ under a capitalised name. List the unwrapped
                  pname too when the process actually runs out of an
                  `-unwrapped` package.
                '';
              };

              reason = lib.mkOption {
                type = lib.types.str;
                description = "Why a version change of this process must not be switched into live. Printed when the node is held.";
              };
            };
          }
        )
      );
      default = { };
      example = lib.literalExpression ''
        {
          hyprland = {
            package = config.programs.hyprland.package;
            reason = "the running compositor; a version bump strands the session on the old binary";
          };
        }
      '';
      description = ''
        Long-lived processes that `switch` never restarts but whose VERSION
        must not move underneath them -- in practice, the running Wayland
        compositor. Keys are display labels.

        ## What this changes

        scripts/switch-preflight.sh and scripts/colmena-apply-drifted.sh find
        every running process whose binary lives in a store path named for
        one of `pnames`, and compare the VERSION it was started from against
        this package's. A different version holds the node: it is reached
        with `boot` + reboot instead of `switch`.

        ## Why version and not store path

        A compositor is a user-session process. Activation does not restart
        it, so the live session keeps running the old binary either way; what
        a switch changes is everything AROUND it -- portals, plugins, IPC
        clients like hyprctl/niri msg, the bar -- which are all suddenly the
        new version talking to the old compositor. That mismatch is a version
        question. A same-version rebuild (a glibc/stdenv mass rebuild) changes
        the hash without changing the protocol, so it is reported but not
        held. Config changes do not touch the package at all, and every
        compositor here hot-reloads its config on switch, so they are not
        held either.

        A process that is not running is not held: only the compositor you
        are actually in matters, not the other ones that happen to be
        installed.

        The display manager needs no entry here. The guard finds it through
        display-manager.service on its own and holds when the target would
        replace it with a different one (see flake/lib/deploy-facts.nix).

        ## Scope

        Linux only (it reads /proc), and the assertion below enforces it.
      '';
    };

    tailscaleAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        This node's Tailscale IPv4 address, as a literal.

        ## Why a literal and not the MagicDNS name

        Everything that RESOLVES a name at runtime should use the MagicDNS
        name instead of this option -- see scrapeAddress, and the feed
        targets in secrets.yaml, which all use `<host>.<tailnet>.ts.net` and
        therefore survive a re-IP with no config change at all.

        This option exists for the cases that cannot do that, all of which
        need a literal address at BIND time:

          * `docker run -p <addr>:<host>:<container>` rejects a hostname
            outright ("docker: invalid IP address: ..." -- verified).
          * Exporter `listenAddress` / `host` options are rendered into unit
            files at build time, long before tailscaled exists to resolve
            anything.

        ## Durability

        Tailscale addresses are stable for as long as the node stays
        registered. They change only if the node is removed from the tailnet
        and re-added, Tailscale is reset or reinstalled, the disk is wiped
        and the node key lost, or an admin reassigns it via the IP pool.

        So: stable in normal operation, but NOT guaranteed across a rebuild.

        ## If the address changes

        Update this one option for the affected host. Every bind on that host
        is derived from it, so there is a single place to edit. The
        `tailscale-address-drift` unit below checks the configured value
        against the running one on every activation and warns loudly if they
        disagree, so a stale value is reported rather than discovered when a
        container fails to start.

        Nothing else needs touching: MagicDNS consumers follow automatically.
      '';
    };
  };

  # The systemd-specific half of this module (the criticalUnits existence
  # check and the tailscale-address-drift unit) lives in
  # modules/base/deployment-meta-linux.nix, imported only by
  # flake/lib/mk-system.nix: nix-darwin has no `systemd` option at all, and
  # `lib.mkIf false { systemd = ...; }` does not avoid that -- mkIf defers the
  # value, but the option path is still resolved during merging, so Darwin
  # fails to evaluate with "The option `systemd' does not exist". The
  # definition has to be absent from this module entirely, which splitting it
  # into a Linux-only file achieves.
  config = {
    assertions = [
      {
        assertion = cfg.internetFacing -> cfg.tailscaleAddress != null;
        message = "deployment.internetFacing requires deployment.tailscaleAddress to be set.";
      }
      {
        assertion = isDarwin -> cfg.criticalUnits == { };
        message = ''
          deployment.criticalUnits is systemd-specific and does nothing on Darwin.
          Declared here: ${lib.concatStringsSep ", " (lib.attrNames cfg.criticalUnits)}
        '';
      }
      {
        assertion = isDarwin -> cfg.criticalProcesses == { };
        message = ''
          deployment.criticalProcesses reads /proc and does nothing on Darwin.
          Declared here: ${lib.concatStringsSep ", " (lib.attrNames cfg.criticalProcesses)}
        '';
      }
    ]
    # The deploy scripts interpolate these names into a shell probe and
    # match them against /proc paths. They validate them again before
    # use, but failing here names the module that declared the bad one.
    ++ lib.mapAttrsToList (label: p: {
      assertion = p.pnames != [ ] && lib.all (n: builtins.match "[A-Za-z0-9._+-]+" n != null) p.pnames;
      message = ''
        deployment.criticalProcesses.${label}.pnames must be a non-empty list of plain
        package names (allowed: letters, digits, . _ + -); got: ${builtins.toJSON p.pnames}
      '';
    }) cfg.criticalProcesses;

    # Unlike the assertion above, a missing scrapeAddress does not break
    # eval -- it just means flake.nix's agentScrapeMap/desktopScrapeMap
    # (see the "Monitoring topology" section of flake.nix) fall back to
    # "<attr>.local" for this node, where <attr> is the nixosConfigurations
    # attribute name (flake.nix:319/334) -- NOT config.networking.hostName.
    # The two are not guaranteed to match (a mismatch already caused a real
    # bug in this repo: an alert rule excluded "daytona" while the actual
    # identifier was "Daytona"). That fallback is the right default for a
    # LAN host with mDNS, and exactly wrong for one whose exporters were
    # just rebound off the LAN by internetFacing itself: Prometheus would
    # keep trying an address the host most likely does not answer on (a
    # bare VPS in particular has no mDNS responder at all), so scrapes
    # fail closed and silently rather than pointing at the Tailscale
    # address this option's own doc comment says to use.
    warnings = lib.optional (cfg.internetFacing && cfg.scrapeAddress == null) ''
      deployment.internetFacing is set on this host, but deployment.scrapeAddress is not.

      Prometheus's target for this node falls back to "<attr>.local", where <attr> is this
      host's nixosConfigurations attribute name in flake.nix (not necessarily
      config.networking.hostName), which is unlikely to resolve for an internet-facing node (no
      LAN mDNS responder), while the exporters themselves are now bound to
      deployment.tailscaleAddress instead of 0.0.0.0. Scraping this host will most likely fail.
      Set deployment.scrapeAddress to this node's Tailscale MagicDNS name (see fredvps's
      configuration.nix for the pattern).
    '';
  };
}
