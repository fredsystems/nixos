# The house watchdog: re-arms Frigate's indoor cameras when Home Assistant's
# heartbeat goes stale. See ./watchdog.py for what it does, and
# ../house-mode.nix for nvrhub's settings.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.house-watchdog;

  watchdog = pkgs.writers.writePython3Bin "house-watchdog" {
    libraries = with pkgs.python3Packages; [
      aiohttp
      paho-mqtt
    ];
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./watchdog.py);
in
{
  options.services.house-watchdog = {
    enable = lib.mkEnableOption "the house watchdog";

    broker = lib.mkOption {
      type = lib.types.str;
      description = "MQTT broker Home Assistant publishes its heartbeat to.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 1883;
      description = "The broker's port.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      description = "Broker user, allowed to read the heartbeat topic.";
    };

    passwordFile = lib.mkOption {
      type = lib.types.path;
      description = "File holding the broker user's password.";
    };

    frigateUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:5000";
      description = "Frigate's unauthenticated loopback listener.";
    };

    cameras = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      description = "Frigate cameras to re-arm.";
    };

    staleAfter = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = ''
        Seconds after the newest heartbeat at which Home Assistant counts as
        gone. Longer than a Home Assistant restart.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "1min";
      description = "How often to check, as a systemd time span.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.house-watchdog = {
      description = "Re-arm Frigate's indoor cameras if Home Assistant is gone";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.escapeShellArgs (
          [
            "${watchdog}/bin/house-watchdog"
            "--broker"
            cfg.broker
            "--port"
            (toString cfg.port)
            "--user"
            cfg.user
            "--password-file"
            "%d/mqtt-password"
            "--state"
            "%S/house-watchdog/heartbeat"
            "--frigate"
            cfg.frigateUrl
            "--stale-after"
            (toString cfg.staleAfter)
          ]
          ++ cfg.cameras
        );
        LoadCredential = [ "mqtt-password:${cfg.passwordFile}" ];
        DynamicUser = true;
        StateDirectory = "house-watchdog";
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
      };
    };

    systemd.timers.house-watchdog = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = cfg.interval;
        AccuracySec = "10s";
      };
    };
  };
}
