# Declared Z-Wave association groups, applied through zwave-js-server: which
# devices a switch commands directly, with no hub involved (what the owner
# calls a scene). See ./associations.py for exactly what is changed; group 1
# (Lifeline) and anything undeclared are never touched.
#
# Runs at boot, whenever zwave-js restarts (PartOf), and whenever the
# declaration changes on a switch.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.zwave-js-associations;

  apply = pkgs.writers.writePython3Bin "zwave-js-associations" {
    libraries = [ pkgs.python3Packages.websockets ];
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./associations.py);

  declaration = pkgs.writeText "zwave-js-associations.json" (
    builtins.toJSON {
      inherit (cfg) url timeout nodes;
    }
  );
in
{
  options.services.zwave-js-associations = {
    enable = lib.mkEnableOption "declared Z-Wave association groups";

    url = lib.mkOption {
      type = lib.types.str;
      default = "ws://127.0.0.1:${toString config.services.zwave-js.port}";
      defaultText = lib.literalExpression ''"ws://127.0.0.1:''${toString config.services.zwave-js.port}"'';
      description = "zwave-js-server's websocket.";
    };

    timeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = "Seconds to wait for zwave-js-server's driver to be ready.";
    };

    nodes = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf (lib.types.listOf lib.types.ints.positive));
      default = { };
      example = {
        "19"."2" = [
          13
          7
        ];
      };
      description = ''
        Source node ID -> association group -> target node IDs. Each declared
        group holds exactly these targets afterwards; groups and nodes not
        listed are left alone. Group 1 (Lifeline) may not be declared.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all (groups: !(groups ? "1")) (lib.attrValues cfg.nodes);
        message = "services.zwave-js-associations: group 1 (Lifeline) is never managed.";
      }
    ];

    systemd.services.zwave-js-associations = {
      description = "Apply declared Z-Wave association groups";
      requires = [ "zwave-js.service" ];
      after = [ "zwave-js.service" ];
      partOf = [ "zwave-js.service" ];
      wantedBy = [
        "zwave-js.service"
        "multi-user.target"
      ];
      # The declaration's store path is in ExecStart, so a changed table
      # changes the unit and a switch restarts it.
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${apply}/bin/zwave-js-associations ${declaration}";
        Restart = "on-failure";
        RestartSec = "60s";
        DynamicUser = true;
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
  };
}
