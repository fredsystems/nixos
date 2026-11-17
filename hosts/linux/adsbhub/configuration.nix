{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  # Restart the consuming container when its --env-file secret changes.
  # See modules/services/mk-container-secret.nix.
  inherit (import ../../../modules/services/mk-container-secret.nix)
    mkContainerSecret
    mkContainerSecrets
    ;
in
{
  # The SDRs and every ADS-B / ACARS container, moved from sdrhub in Plan 05
  # (agent-docs/plans/PLAN_05_SDRHUB_SPLIT.md). Not profiles/adsb-hub.nix:
  # that brings GitHub runners, which this host (like sdrhub) does not run.
  imports = [
    ./hardware-configuration.nix
    ../../../modules/secrets/sops.nix
    ../../../modules/services/adsb-docker-units.nix
    ../../../modules/services/sqlite-backup.nix
    ../../../modules/services/beast-compare.nix
    ../../../modules/services/tailscale
    ../../../modules/monitoring/agent
    ../../../modules/hardware/usbfs.nix
    ../../../modules/data/docker-image-pins.nix
  ];

  networking.hostName = "adsbhub";

  deployment.role = "monitoring-agent";

  sops_secrets.enable_secrets.enable = true;

  # This host has USB SDR hardware attached; raise the global usbfs
  # transfer-buffer ceiling above the 16 MB kernel default.
  hardware-profile.usbfs.enable = true;

  # CPU temperature for the containers that expect a Raspberry Pi's
  # /sys/class/thermal/thermal_zone0/temp: rbfeeder segfaults without it
  # (sdr-enthusiasts/docker-airnavradar, version_0.4.3_workarounds.md), and
  # graphs1090 in ultrafeeder and tar1090_airspy reads it for its temperature
  # chart. This host has no thermal zones at all; its CPU temperature is
  # k10temp's Tctl, under a hwmonN whose number depends on probe order. So
  # the link is made at boot, by name, and the directory holding it is
  # mounted over each container's /sys/class/thermal. The link resolves
  # inside the container, whose /sys shows the host's hwmon devices.
  boot.kernelModules = [ "k10temp" ];

  systemd.services =
    let
      consumers = [
        "docker-rbfeeder"
        "docker-ultrafeeder"
        "docker-tar1090_airspy"
      ];
      ordering = {
        wants = [ "adsb-thermal-zone.service" ];
        after = [ "adsb-thermal-zone.service" ];
      };
    in
    {
      adsb-thermal-zone = {
        description = "Expose k10temp Tctl as thermal_zone0 for the ADS-B containers";
        wantedBy = [ "multi-user.target" ];
        after = [ "systemd-modules-load.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          for h in /sys/class/hwmon/hwmon*; do
            if [ "$(cat "$h/name")" = k10temp ]; then
              install -d -m 0755 /run/adsb-thermal/thermal_zone0
              ln -sfn "$h/temp1_input" /run/adsb-thermal/thermal_zone0/temp
              exit 0
            fi
          done
          echo "no k10temp hwmon device found" >&2
          exit 1
        '';
      };
    }
    // lib.genAttrs consumers (_: ordering);

  services = {
    ###########################################
    # beast-compare recorder
    ###########################################
    # Plan 02: record every 1090 receiver on the shared antenna. Change runId
    # whenever the setup changes (a receiver, an attenuator, a splitter
    # port); see modules/services/beast-compare.nix.
    #
    # Off until the four-receiver runs (2.14, 2.15). 2026-11-baseline-b, the
    # planned second half of 2.12, was dropped after three hours: the Airspy
    # was losing about 19% of its samples here (its counter ran at 9.77 MHz,
    # not 12) because it shares a USB 2.0 bus with both RTL-SDRs, and 2.15's
    # port rotation measures the port term anyway. Fix the USB layout and set
    # a new runId before re-enabling; reusing baseline-b's would append to it.
    # The Pro Stick Plus's decoder (tar1090_rtlsdr) has been removed, so its
    # receiver entry goes back in with that container.
    beastCompare = {
      enable = false;
      package = inputs.beast-compare.packages.${pkgs.stdenv.hostPlatform.system}.default;
      runId = "2026-11-baseline-b";
      receivers = [
        {
          name = "airspy";
          beast = "127.0.0.1:30105";
          statsFile = "/opt/adsb/data/airspy_adsb/stats.json";
          metadata = {
            sdr = "Airspy R2";
            decoder = "airspy_adsb";
            attenuation_db = "0";
            splitter_port = "1";
          };
        }
      ];
    };

    adsb.containers = [
      ###############################################################
      # DOZZLE AGENT
      ###############################################################
      (import ../../../modules/services/mk-dozzle-agent.nix {
        image = config.shared.dockerImages.dozzle;
      })

      ###############################################################
      # AIRSPY ADS-B RECEIVER
      ###############################################################
      {
        name = "airspy_adsb";
        image = config.shared.dockerImages.airspyAdsb;

        hostname = "airspy_adsb";
        restart = "always";
        tty = false;

        environmentFiles = [
          config.sops.secrets."docker/adsbhub/airspy_adsb.env".path
        ];

        # 12 MSPS, not 20. After adsbhub's reboot on 2026-11-16 every MLAT
        # server reported this receiver's clock as unstable (piaware "clock
        # unstable", adsb.lol 44% bad sync) for 17 hours, at 20 MSPS on a USB
        # 2.0 bus shared with the 978 RTL-SDR (~44 MB/s of demand). airspy_adsb's
        # maintainer recommends 12 for exactly that symptom: "20 MSPS will
        # more easily cause MLAT issues so if you find you have bad sync /
        # clock unstable, best to go to 12 MSPS" (wiedehopf/airspy-conf), for
        # a cost he puts at under 3% of positions. 12 also halves the
        # Airspy's USB load to ~24 MB/s. Revisit once the Airspy has a bus to
        # itself. Set here rather than in the env file because it is not
        # secret; the container prefers this over the legacy
        # AIRSPY_ADSB_MLAT_FREQ, which has been removed from the env file.
        environment = {
          AIRSPY_ADSB_SAMPLE_RATE = "12";
        };

        deviceCgroupRules = [
          "c 189:* rwm"
        ];

        # Raw Beast output for the beast-compare recorder, loopback only.
        ports = [
          "127.0.0.1:30105:30005"
        ];

        volumes = [
          "/dev:/dev"
          "/opt/adsb/data/airspy_adsb:/run/airspy_adsb"
        ];
      }

      ###############################################################
      # TAR1090 (airspy only)
      ###############################################################
      # A view of what the Airspy alone is receiving, for comparing it
      # against the combined picture in ultrafeeder. Its only input is
      # airspy_adsb's Beast output; no MLAT, no connectors out, and none of
      # readsb's feed ports are published.
      {
        name = "tar1090_airspy";
        image = config.shared.dockerImages.tar1090;

        hostname = "tar1090_airspy";
        restart = "always";
        tty = false;

        dependsOn = [ "airspy_adsb" ];

        # TZ, LAT and LONG (the receiver position, for the range outline).
        environmentFiles = [
          config.sops.secrets."docker/adsbhub/tar1090_airspy.env".path
        ];

        environment = {
          BEASTHOST = "airspy_adsb";
          BEASTPORT = "30005";
          TAR1090_PAGETITLE = "adsbhub - airspy";
          TAR1090_SITESHOW = "true";
          TAR1090_ENABLE_AC_DB = "true";
          ENABLE_AIRSPY = "true";
        };

        ports = [
          "8088:80"
        ];

        volumes = [
          "/opt/adsb/data/tar1090_airspy/globe_history:/var/globe_history"
          "/opt/adsb/data/tar1090_airspy/graphs1090:/var/lib/collectd"
          "/opt/adsb/data/airspy_adsb:/run/airspy_adsb:ro"
          "/run/adsb-thermal:/sys/class/thermal:ro"
        ];

        tmpfs = [
          "/run:exec,size=256M"
          "/tmp:size=128M"
          "/var/log:size=32M"
        ];
      }

      ###############################################################
      # ULTRAFEEDER (readsb) — central ADS-B decoder
      ###############################################################
      {
        name = "ultrafeeder";
        image = config.shared.dockerImages.adsbUltrafeeder;

        hostname = "ultrafeeder";
        restart = "always";
        tty = false;

        environmentFiles = [
          config.sops.secrets."docker/adsbhub/ultrafeeder.env".path
        ];

        # Network-only: ultrafeeder opens no SDR itself. Its 1090 input is
        # airspy_adsb (beast_in in ultrafeeder.env), and it deliberately gets
        # no USB access, so it cannot pick up the 1090 RTL-SDR (serial
        # 00001090) by accident. Feeding that RTL into ultrafeeder alongside
        # the airspy would merge two receivers with unsynchronised clocks into
        # one MLAT station, which is what broke MLAT while both were in it.
        ports = [
          "8080:80"
          "30002:30002"
          "30003:30003"
          "30005:30005"
          "30047:30047"
          "12000:12000"
          "9273-9274:9273-9274"
        ];

        volumes = [
          "/opt/adsb/data/ultra_globe_history:/var/globe_history"
          "/opt/adsb/data/ultra_graphs1090:/var/lib/collectd"
          "/proc/diskstats:/proc/diskstats:ro"
          "/opt/adsb/data/airspy_adsb:/run/airspy_adsb"
          "/run/adsb-thermal:/sys/class/thermal:ro"
        ];

        tmpfs = [
          "/run:exec,size=256M"
          "/tmp:size=128M"
          "/var/log:size=32M"
        ];
      }

      ###############################################################
      # dump978 — UAT / 978 MHz decoder
      ###############################################################
      {
        name = "dump978";
        # telegraf-build-801, not latest-build-801: the same application build,
        # but the `latest-*` variant does not ship the telegraf binary, and both
        # the telegraf and telegraf_socat s6 services `sleep infinity` without
        # it. That made ENABLE_PROMETHEUS / PROMETHEUSPORT / PROMETHEUSPATH
        # silently inert -- the s6 services reported "up" while nothing listened
        # on 9275, so the published port accepted connections via docker-proxy
        # and immediately reset them.
        #
        # With the binary present, /etc/s6-overlay/scripts/04-telegraf generates
        # outputs_prometheus.conf from those same env vars, which are already
        # set correctly below, so no other change is needed.
        #
        # Cost: the telegraf binary is ~310 MB uncompressed.
        image = config.shared.dockerImages.dump978;

        hostname = "dump978";
        restart = "always";
        tty = true;

        environmentFiles = [
          config.sops.secrets."docker/adsbhub/dump978.env".path
        ];

        # Suppress telegraf's per-aircraft socket listener.
        #
        # Without this, telegraf emits 23 metric families keyed on `address`,
        # `callsign` and `flightplan_id` -- one set per aircraft seen. That is
        # unbounded cardinality: observed growing from 230 to 286 series within
        # an hour, and with 90d retention every aircraft ever seen would leave
        # 23 series behind permanently. It is also useless for monitoring;
        # per-aircraft state is what tar1090 and skyaware978 are for.
        #
        # The aggregate inputs (stats_*, polar_range_*) are unaffected and are
        # what the scrape job actually wants: total_accepted_messages,
        # total_tracks, tracks_with_position, avg_accepted_rssi, max_distance_m.
        environment = {
          INFLUXDB_SKIP_AIRCRAFT = "true";
        };

        deviceCgroupRules = [
          "c 189:* rwm"
        ];

        ports = [
          "8083:80"
          "9275:9275"
        ];

        volumes = [
          "/opt/adsb/data/dump978_autogain:/var/globe_history"
          "/dev:/dev"
        ];

        tmpfs = [
          "/run/readsb"
          "/var/log"
        ];
      }

      ###############################################################
      # ADSBHub feeder
      ###############################################################
      # Named adsbhub_feeder rather than adsbhub so it does not share a
      # name with this host in docker, cAdvisor and Loki labels.
      {
        name = "adsbhub_feeder";
        image = config.shared.dockerImages.adsbhub;

        restart = "always";
        tty = true;

        environmentFiles = [
          config.sops.secrets."docker/adsbhub/adsbhub_feeder.env".path
        ];

        tmpfs = [
          "/run:exec,size=64M"
          "/var/log"
        ];
      }

      ###############################################################
      # Flightradar24 feeder
      ###############################################################
      {
        name = "fr24";
        image = config.shared.dockerImages.flightradar24;

        restart = "always";
        tty = true;

        ports = [
          "8082:8754"
        ];

        environmentFiles = [
          config.sops.secrets."docker/adsbhub/fr24.env".path
        ];

        tmpfs = [
          "/run:exec,size=64M"
          "/var/log"
        ];
      }

      ###############################################################
      # PiAware (FlightAware)
      ###############################################################
      {
        name = "piaware";
        image = config.shared.dockerImages.piaware;

        hostname = "piaware";
        restart = "always";
        tty = true;

        ports = [
          "8084:80"
        ];

        environmentFiles = [
          config.sops.secrets."docker/adsbhub/piaware.env".path
        ];

        tmpfs = [
          "/run:exec,size=64M"
          "/var/log"
        ];
      }

      ###############################################################
      # PlaneFinder feeder
      ###############################################################
      {
        name = "planefinder";
        image = config.shared.dockerImages.planefinder;

        restart = "always";
        tty = true;

        ports = [
          "8087:30053"
        ];

        environmentFiles = [
          config.sops.secrets."docker/adsbhub/planefinder.env".path
        ];

        tmpfs = [
          "/run:exec,size=64M"
          "/var/log"
        ];
      }

      ###############################################################
      # PlaneWatch feeder
      ###############################################################
      {
        name = "planewatch";
        image = config.shared.dockerImages.planewatch;

        restart = "always";
        tty = true;

        environmentFiles = [
          config.sops.secrets."docker/adsbhub/planewatch.env".path
        ];

        tmpfs = [
          "/run:exec,size=64M"
          "/var/log"
        ];
      }

      ###############################################################
      # RadarVirtuel feeder
      ###############################################################
      {
        name = "radarvirtuel";
        image = config.shared.dockerImages.radarvirtuel;

        hostname = "radarvirtuel";
        restart = "always";
        tty = true;

        environmentFiles = [
          config.sops.secrets."docker/adsbhub/radarvirtuel.env".path
        ];

        tmpfs = [
          "/tmp:rw,nosuid,nodev,noexec,relatime,size=128M"
          "/run:exec,size=64M"
          "/var/log"
        ];

        volumes = [
          "/opt/adsb/data/radarvirtuel:/data:rw"
          "/opt/adsb/data/fake_cpuinfo:/proc/cpuinfo:ro"
          "/etc/localtime:/etc/localtime:ro"
          "/etc/timezone:/etc/timezone:ro"
        ];
      }

      ###############################################################
      # RBFeeder / AirNav RadarBox
      ###############################################################
      {
        name = "rbfeeder";
        image = config.shared.dockerImages.airnavradar;

        restart = "always";
        tty = false;

        environmentFiles = [
          config.sops.secrets."docker/adsbhub/rbfeeder.env".path
        ];

        volumes = [
          "/opt/adsb/data/fake_cpuinfo:/proc/cpuinfo"
          "/run/adsb-thermal:/sys/class/thermal:ro"
        ];

        tmpfs = [
          "/run:exec,size=64M"
          "/var/log"
        ];
      }

      ###############################################################
      # OpenSky Network Feeder
      ###############################################################
      {
        name = "opensky";
        image = config.shared.dockerImages.openskyNetwork;

        restart = "always";
        tty = true;

        environmentFiles = [
          config.sops.secrets."docker/adsbhub/opensky.env".path
        ];

        tmpfs = [
          "/run:exec,size=64M"
          "/var/log"
        ];
      }

      ###############################################################
      # SDRMAP
      ###############################################################
      {
        name = "sdrmap";
        image = config.shared.dockerImages.sdrmap;

        restart = "always";

        environmentFiles = [
          config.sops.secrets."docker/adsbhub/sdrmap.env".path
        ];
      }

      ###############################################################
      # ACARSHUB (ACARS/VHFM/VDLM ingestion + UI)
      ###############################################################
      {
        name = "acarshub";
        image = config.shared.dockerImages.acarshub;

        restart = "always";
        tty = true;

        ports = [
          "8085:80"
        ];

        environmentFiles = [
          config.sops.secrets."docker/adsbhub/acarshub.env".path
        ];

        volumes = [
          "/opt/adsb/data/acarshub:/run/acars"
        ];

        tmpfs = [
          "/database:exec,size=64M"
          "/run:exec,size=64M"
          "/var/log"
        ];
      }

      ###############################################################
      # ACARSHUB v4 (ACARS/VHFM/VDLM ingestion + UI)
      ###############################################################
      {
        name = "acarshubv4";
        image = config.shared.dockerImages.acarshubV4;

        restart = "always";
        tty = true;

        ports = [
          "8086:80"
        ];

        environmentFiles = [
          config.sops.secrets."docker/adsbhub/acarshub.env".path
        ];

        volumes = [
          "/opt/adsb/data/acarshubv4:/run/acars"
        ];

        tmpfs = [
          "/database:exec,size=64M"
          "/run:exec,size=64M"
          "/var/log"
        ];
      }

      {
        name = "acars2pos";
        #image = config.shared.dockerImages.acars2posAlt;
        image = config.shared.dockerImages.acars2pos;

        restart = "always";
        tty = true;

        # Drop the periodic per-airline statistics dump.
        #
        # Measured 2026-08-18: this container emitted 15,510 journal
        # lines/hour, of which 13,731 -- 88.5% -- were one pretty-printed
        # Python dict re-emitted roughly every 20 seconds, 80 lines per burst,
        # one line per airline code. Every line looks like
        #
        #   {'81': {'airframes': 0, 'python': 0, 'total': 1},
        #    'AA': {'airframes': 0, 'python': 0, 'total': 1},
        #
        # It was also double-counted: docker.service relays container stdout,
        # so the same 14k lines/hour appeared a second time under that unit,
        # making the pair the top two journal producers on this host after
        # Loki itself.
        #
        # The image has no verbosity control, so this is filtered here instead.
        # The pattern anchors on the `'XX': {'airframes'` shape rather than the
        # bare word, so it catches both the opening line and the
        # leading-whitespace continuations while leaving anything else that
        # merely mentions airframes alone. Verified against real burst output
        # with systemd-run before landing: all three dict line shapes dropped,
        # "matched message type" and "acars NN" preserved.
        #
        # Position data itself is untouched -- this drops only the aggregate
        # counters, which are visible in Prometheus anyway.
        logFilterPatterns = [ "~'[^']*': \\{'airframes'" ];

        environmentFiles = [
          config.sops.secrets."docker/adsbhub/acars2pos.env".path
        ];

        tmpfs = [
          "/database:exec,size=64M"
          "/run:exec,size=64M"
          "/var/log"
        ];
      }

      ###############################################################
      # ACARS ROUTER (ACARS + VDLM2 + HFDL consolidation)
      ###############################################################
      {
        name = "acars_router";
        image = config.shared.dockerImages.acarsRouter;

        restart = "always";
        tty = true;

        ports = [
          "15550:15550"
          "15555:15555"
          "15556:15556"
          "35550:35550"
          "35555:35555"
          "35556:35556"
          "45550:45550"
          "45555:45555"
          "45556:45556"
          "5550:5550"
          "5556:5556"
        ];

        environmentFiles = [
          config.sops.secrets."docker/adsbhub/acars_router.env".path
        ];

        tmpfs = [
          "/run:exec,size=64M"
          "/var/log"
        ];
      }
    ];

    # Consistent dumps of the two ACARS message databases.
    #
    # These are the only data under /opt/adsb that genuinely needs backing up,
    # and until now they were the part being backed up WORST: the NAS's nightly
    # rsync of /opt/adsb copied both live, WAL-mode, mid-write, which is the
    # exact defect the audit found and fixed in discord-backup.nix. Everything
    # else in that tree -- influxdb_data, tar1090_heatmap, vrs, pihole,
    # fam_webapp -- is cache or regenerable state, and accounts for 9.17 of the
    # 11.99 GiB the pull currently transfers. Measured 2026-08-18:
    #
    #   acarshub   messages.db  1.41 GiB   \ 2.82 GiB, i.e. 24% of the tree
    #   acarshubv4 messages.db  1.41 GiB   /
    #
    # Written into /opt/adsb/backups so the existing NAS job collects them with
    # no change at the NAS end. That placement is deliberate but has a
    # consequence worth knowing: the NAS pull passes --delete, so local retention
    # is mirrored rather than accumulated off-host. See BACKUP-DESIGN.md Part 3.
    #
    # Verified on this host before landing: `.backup` against the live database
    # takes ~5s per 1.4 GB, and the resulting dump passes integrity_check with
    # 3,448,426 rows and all five messages_fts* shadow tables present.
    sqliteBackup = {
      enable = true;

      databases = {
        acarshub = {
          source = "/opt/adsb/data/acarshub/messages.db";
          destination = "/opt/adsb/backups";
          name = "acarshub-messages";
        };

        acarshubv4 = {
          source = "/opt/adsb/data/acarshubv4/messages.db";
          destination = "/opt/adsb/backups";
          name = "acarshubv4-messages";
        };
      };
    };

    # Watch the dumps above, same as the Prometheus snapshots and the Discord
    # database. Without this they would be exactly what the rest of this fleet's
    # backups were before the freshness work: files nobody looks at, whose
    # absence is indistinguishable from health.
    #
    backupFreshness.enable = true;
    backupFreshness.artifacts = {
      acarshub-db = {
        path = "/opt/adsb/backups";
        pattern = "acarshub-messages-*.sqlite";

        # 30 hours, matching the other nightly artifacts: the timer is 00:30 plus
        # up to 10 minutes of jitter, so a healthy newest-dump age peaks a little
        # over 24h just before each run.
        maxAgeSeconds = 108000;

        # keep = 3 in the sqliteBackup declaration above, so 3 is the steady
        # state. 5 catches the retention prune having stopped before three 1.4 GB
        # dumps become ten.
        maxCount = 5;

        description = "ACARSHub message database (acarshub)";
      };

      acarshubv4-db = {
        path = "/opt/adsb/backups";
        pattern = "acarshubv4-messages-*.sqlite";
        maxAgeSeconds = 108000;
        maxCount = 5;
        description = "ACARSHub message database (acarshubv4)";
      };
    };
  };

  system.activationScripts.adsbDockerCompose = {
    text = ''
      install -d -m0755 -o ${config.shared.user.name} -g users /opt/adsb
    '';
    deps = [ ];
  };

  sops.secrets = {
    "docker/adsbhub/airspy_adsb.env" = mkContainerSecret "airspy_adsb";

    "docker/adsbhub/tar1090_airspy.env" = mkContainerSecret "tar1090_airspy";

    "docker/adsbhub/ultrafeeder.env" = mkContainerSecret "ultrafeeder";

    "docker/adsbhub/dump978.env" = mkContainerSecret "dump978";

    "docker/adsbhub/adsbhub_feeder.env" = mkContainerSecret "adsbhub_feeder";

    "docker/adsbhub/fr24.env" = mkContainerSecret "fr24";

    "docker/adsbhub/piaware.env" = mkContainerSecret "piaware";

    "docker/adsbhub/planefinder.env" = mkContainerSecret "planefinder";

    "docker/adsbhub/planewatch.env" = mkContainerSecret "planewatch";

    "docker/adsbhub/radarvirtuel.env" = mkContainerSecret "radarvirtuel";

    "docker/adsbhub/rbfeeder.env" = mkContainerSecret "rbfeeder";

    "docker/adsbhub/opensky.env" = mkContainerSecret "opensky";

    "docker/adsbhub/sdrmap.env" = mkContainerSecret "sdrmap";

    "docker/adsbhub/acars_router.env" = mkContainerSecret "acars_router";

    "docker/adsbhub/acars2pos.env" = mkContainerSecret "acars2pos";

    # Shared by both acarshub and acarshubv4; each must pick up the change.
    "docker/adsbhub/acarshub.env" = mkContainerSecrets [
      "acarshub"
      "acarshubv4"
    ];
  };
}
