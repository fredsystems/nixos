# modules/monitoring/agent/smartctl.nix
#
# SMART disk pre-failure monitoring via prometheus-smartctl-exporter.
#
# WHY
#
# node_exporter's diskstats collector reports throughput and latency, and the
# filesystem collector reports free space. Neither reports the drive's own
# assessment of whether it is about to die. Every host in this fleet runs a
# single NVMe SSD with no redundancy, and the decoders write continuously
# (37.8 TB written on sdrhub), so endurance exhaustion is a realistic failure
# mode that nothing currently observes.
#
# WHAT THE FLEET ACTUALLY EXPOSES (verified 2026-08-03 with smartctl 7.5)
#
#   host      device      %used  spare  spare_thresh  media_err  power_on_h
#   sdrhub    nvme0          54    100            10          0      24,878
#   hfdlhub1  nvme0           5    100            10          0      22,593
#   hfdlhub2  nvme0           5    100            10          0      22,590
#   acarshub  nvme0           1    100            50          0       9,376
#   vdlmhub   nvme0           1    100            50          0       9,289
#   fredhub   nvme0           2    100            10          0         200
#
# Two things to note, because they drive decisions below:
#
#   1. sdrhub's Lexar NM620 is already at 54% of its rated write endurance.
#      This is the reason this module exists.
#   2. acarshub and vdlmhub report an Available Spare Threshold of 50%, not
#      the 10% the other four report. A hardcoded "spare < 10%" alert would
#      be wrong for those two, so the critical spare rule in
#      ../master/alert-rules/smart-alerts.yaml compares against the drive's
#      own reported threshold rather than a constant.
#
# PRIVILEGES
#
# Nothing is added here. The nixpkgs module already grants exactly what
# smartctl needs and no more:
#   - AmbientCapabilities  = CAP_SYS_RAWIO, CAP_SYS_ADMIN
#   - DeviceAllow          = block-blkext, block-sd, char-nvme (rw)
#   - SupplementaryGroups  = disk, smartctl-exporter-access
#   - PrivateDevices       = false (forced off, it would hide the disks)
# It also creates the smartctl-exporter-access group and installs a udev rule
# that setfacl's g:smartctl-exporter-access:rw onto /dev/nvme[0-9]*, so the
# exporter runs as an unprivileged system user rather than root.
{
  config,
  lib,
  pkgs,
  agentNodes,
  agentScrapeMap,
  ...
}:
let
  # 9633 is the exporter's upstream default. Confirmed unused elsewhere in
  # this repo (the taken set is 80, 443, 2269, 3333, 4567, 5432, 5678, 6379,
  # 8078, 9090, 9093, 9100).
  port = 9633;

  # fredvps is a QEMU guest. Its virtual disk answers:
  #   Product: QEMU HARDDISK
  #   SMART support is: Unavailable - device lacks SMART capability.
  # There is no SMART data to collect, so enabling a CAP_SYS_RAWIO /
  # CAP_SYS_ADMIN service there adds attack surface for zero signal. It is
  # excluded from both the exporter and the scrape job.
  hostsWithoutSmart = [ "fredvps" ];

  hasSmart = !builtins.elem config.networking.hostName hostsWithoutSmart;

  smartAgents = builtins.filter (h: !builtins.elem h hostsWithoutSmart) agentNodes;

  # This module is imported by every agent (via profiles/adsb-hub.nix) and by
  # sdrhub, which is also the master. scrapeConfigs is a listOf and merges
  # across modules, so the master-side scrape job can be defined here instead
  # of in ../master/prometheus.nix. Gating on services.prometheus.enable is
  # what makes that safe: only sdrhub enables Prometheus, so only sdrhub
  # contributes the job. No mkDefault anywhere -- a mkDefault list is
  # discarded wholesale by any normal-priority definition rather than merged.
  isMaster = config.services.prometheus.enable;
in
{
  config = lib.mkMerge [
    (lib.mkIf hasSmart {
      services.prometheus.exporters.smartctl = {
        enable = true;

        # The master scrapes this across the LAN, so it cannot bind loopback.
        listenAddress = "0.0.0.0";
        inherit port;

        # Each collection forks smartctl once per device. maxInterval caches
        # the result, so this is the real query rate against the drive; the
        # scrape job below uses a matching 60s interval so a scrape does not
        # simply re-serve a cached sample four times.
        maxInterval = "60s";

        # devices is left at its default of [ ], which autodiscovers via
        # `smartctl --scan`. On this fleet that yields exactly
        # "/dev/nvme0 -d nvme", labelled device="nvme0" by the exporter
        # (it strips /dev/ and replaces / with _).
      };

      networking.firewall.allowedTCPPorts = [
        port # smartctl_exporter
      ];

      # The nixpkgs module ships a udev rule that setfacl's
      # g:smartctl-exporter-access:rw onto /dev/nvme[0-9]*, but it is gated on
      # ACTION=="add". That fires when the kernel creates the device node at
      # boot, and never again -- so deploying this module to a running system
      # leaves /dev/nvme0 as crw------- root root, the exporter gets EACCES,
      # and it serves `smartctl_devices 1` with no device metrics at all while
      # its scrape target still reports up.
      #
      # Capabilities do not help: the unit has CAP_SYS_RAWIO and CAP_SYS_ADMIN,
      # but neither bypasses DAC permission checks (only CAP_DAC_OVERRIDE
      # would, which is a far bigger grant than an ACL on one device node).
      #
      # So apply the ACL explicitly, ordered before the exporter. Idempotent,
      # and it makes the exporter work on the deploy that enables it rather
      # than only after the next reboot.
      systemd.services.smartctl-exporter-device-acl = {
        description = "Grant smartctl_exporter read access to NVMe control devices";
        wantedBy = [ "multi-user.target" ];
        before = [ "prometheus-smartctl-exporter.service" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        script = ''
          shopt -s nullglob
          for dev in /dev/nvme[0-9]*; do
            # Only the controller character devices (/dev/nvme0). The namespace
            # block devices (/dev/nvme0n1) are a different subsystem and are
            # not what smartctl opens.
            [ -c "$dev" ] || continue
            ${pkgs.acl}/bin/setfacl -m g:smartctl-exporter-access:rw "$dev"
          done
        '';
      };

      # Ordering alone is not enough on a live deploy: without an explicit
      # dependency the exporter unit is unchanged and systemd has no reason to
      # restart it, so it keeps its cached "device not found" state. Requiring
      # the ACL unit changes the exporter's definition, which makes activation
      # restart it after the ACL is in place.
      systemd.services.prometheus-smartctl-exporter = {
        requires = [ "smartctl-exporter-device-acl.service" ];
        after = [ "smartctl-exporter-device-acl.service" ];
      };
    })

    (lib.mkIf isMaster {
      # hostname and role are attached here because the exporter's own
      # metrics carry only a `device` label. Alerts template
      # {{ $labels.hostname }}, which is empty unless the scrape job
      # supplies it -- the same defect that has been fixed elsewhere in this
      # stack. Mirrors the node and cadvisor jobs in ../master/prometheus.nix.
      services.prometheus.scrapeConfigs = [
        {
          job_name = "smartctl";
          scrape_interval = "60s";
          static_configs =
            (map (h: {
              targets = [ "${agentScrapeMap.${h}}:${toString port}" ];
              labels = {
                hostname = h;
                role = "agent";
                exporter = "smartctl";
              };
            }) smartAgents)
            ++ [
              {
                targets = [ "sdrhub.local:${toString port}" ];
                labels = {
                  hostname = "sdrhub";
                  role = "master";
                  exporter = "smartctl";
                };
              }
            ];
        }
      ];

      services.prometheus.ruleFiles = [
        ../master/alert-rules/smart-alerts.yaml
      ];
    })
  ];
}
