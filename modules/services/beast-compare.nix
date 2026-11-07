# Records the Beast output of several ADS-B receivers side by side, for
# beast-compare's transmission-by-transmission comparison (plan 02,
# agent-docs/plans/PLAN_02_RECEIVER_COMPARISON.md).
#
# A RUN IS ITS CONFIGURATION
#
# The recorder writes its configuration into the run's manifest and refuses
# to resume a run under a different one, so that one run directory always
# describes one physical setup. Changing anything here (a receiver, an
# endpoint, metadata such as attenuation) without also changing `runId`
# leaves the service failing on restart with "recorded with a different
# configuration". That is intended: change `runId` for every new setup.
#
# SOURCES
#
# Each receiver must be one decoder's unreduced Beast output (readsb's or
# airspy_adsb's 30005), never an aggregator such as ultrafeeder's 30005,
# which re-emits several receivers' messages and would contaminate the
# comparison.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.beastCompare;

  receiverModule = {
    options = {
      name = lib.mkOption {
        type = lib.types.strMatching "[a-z0-9][a-z0-9-]*";
        example = "airspy";
        description = "Receiver name: its directory in the run and its label in reports.";
      };

      beast = lib.mkOption {
        type = lib.types.str;
        example = "127.0.0.1:30105";
        description = "host:port of the decoder's unreduced Beast output.";
      };

      statsUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "http://127.0.0.1:8089/data/stats.json";
        description = "URL of the decoder's stats.json, polled once a minute.";
      };

      statsFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/opt/adsb/data/airspy_adsb/stats.json";
        description = "Path of the decoder's stats.json, read once a minute.";
      };

      metadata = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          sdr = "Airspy R2";
          attenuation_db = "0";
        };
        description = "Free-form facts about the receiver chain, recorded with the run.";
      };
    };
  };

  receiverConfig =
    r:
    {
      inherit (r) name beast metadata;
    }
    // lib.optionalAttrs (r.statsUrl != null) { stats.url = r.statsUrl; }
    // lib.optionalAttrs (r.statsFile != null) { stats.file = r.statsFile; };

  # JSON is valid YAML, and beast-compare reads it with a YAML loader.
  configFile = pkgs.writeText "beast-compare-recorder.yaml" (
    builtins.toJSON {
      run_id = cfg.runId;
      data_dir = cfg.dataDir;
      receivers = map receiverConfig cfg.receivers;
    }
  );
in
{
  options.services.beastCompare = {
    enable = lib.mkEnableOption "the beast-compare recorder";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The beast-compare package.";
    };

    runId = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9._-]*";
      example = "2026-11-baseline";
      description = ''
        Name of the run being recorded. Change it whenever the setup changes;
        see the header of this module.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/opt/adsb/data/beast-compare";
      description = "Directory holding one subdirectory per run.";
    };

    receivers = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule receiverModule);
      description = "The receivers to record.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = map (r: {
      assertion = r.statsUrl == null || r.statsFile == null;
      message = "services.beastCompare: receiver ${r.name} sets both statsUrl and statsFile.";
    }) cfg.receivers;

    users.users.beast-compare = {
      isSystemUser = true;
      group = "beast-compare";
    };
    users.groups.beast-compare = { };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 beast-compare beast-compare -"
    ];

    systemd.services.beast-compare-recorder = {
      description = "beast-compare recorder (run ${cfg.runId})";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "docker.service"
      ];

      serviceConfig = {
        ExecStart = "${lib.getExe cfg.package} record --config ${configFile}";
        User = "beast-compare";
        Group = "beast-compare";
        Restart = "always";
        RestartSec = 10;

        ReadWritePaths = [ cfg.dataDir ];
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
      };
    };
  };
}
