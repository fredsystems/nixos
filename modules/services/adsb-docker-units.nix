{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.adsb;

  # Convert attrset → "-e KEY=value"
  mkEnvFlags = env: lib.concatStringsSep " " (lib.mapAttrsToList (k: v: ''-e "${k}=${v}"'') env);

  # env files → "--env-file /path"
  mkEnvFileFlags = files: lib.concatStringsSep " " (map (f: ''--env-file "${f}"'') files);

  # "/src:dst:mode" → "-v /src:dst:mode"
  mkVolumeFlags = vols: lib.concatStringsSep " " (map (v: ''-v "${v}"'') vols);

  # tmpfs mounts
  mkTmpfsFlags = tmp: lib.concatStringsSep " " (map (t: ''--tmpfs "${t}"'') tmp);

  # ports
  mkPortFlags = ports: lib.concatStringsSep " " (map (p: ''-p "${p}"'') ports);

  mkDeviceCgroupRuleFlags =
    rules: lib.concatStringsSep " " (map (r: ''--device-cgroup-rule="${r}"'') rules);

  mkDeviceFlags = devs: lib.concatStringsSep " " (map (d: ''--device="${d}"'') devs);

  mkUnit =
    c:
    let
      envFlags = mkEnvFlags (c.environment or { });
      envFileFlags = mkEnvFileFlags (c.environmentFiles or [ ]);
      volumeFlags = mkVolumeFlags (c.volumes or [ ]);
      tmpfsFlags = mkTmpfsFlags (c.tmpfs or [ ]);
      portFlags = mkPortFlags (c.ports or [ ]);
      restartPolicy = c.restart or "always";
      execCmd = c.exec or "";
      ttyFlag = if (c.tty or false) then "--tty" else "";
      deviceRuleFlags = mkDeviceCgroupRuleFlags (c.deviceCgroupRules or [ ]);
      deviceFlags = mkDeviceFlags (c.devices or [ ]);
    in
    {
      description = "Docker Container ${c.name}";
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Restart = restartPolicy;
        TimeoutStartSec = 0;

        ExecStartPre = [
          "-${pkgs.docker}/bin/docker rm -f ${c.name}"
          "${pkgs.docker}/bin/docker pull ${c.image}"
        ];

        ExecStart =
          lib.escapeShellArgs [
            "${pkgs.docker}/bin/docker"
            "run"
            "--name"
            c.name
            "--network"
            "adsbnet"
          ]
          + " ${ttyFlag} ${deviceRuleFlags} ${deviceFlags} ${envFlags} ${envFileFlags} ${volumeFlags} ${tmpfsFlags} ${portFlags} "
          + (c.extraDockerArgs or "")
          + " ${c.image} ${execCmd}";

        ExecStop = "${pkgs.docker}/bin/docker stop ${c.name}";
        ExecStopPost = "-${pkgs.docker}/bin/docker rm ${c.name}";
      };

      requires = [ "docker.service" ];
      after = [
        "docker.service"
        "network-online.target"
        "docker-create-adsbnet.service"
      ];
      wants = [ "network-online.target" ];
    };
in
{
  options.services.adsb.containers = lib.mkOption {
    type = lib.types.listOf lib.types.attrs;
    default = [ ];
    description = "List of ADS-B/ACARS/SDR containers to run under Docker.";
  };

  config = lib.mkIf (cfg.containers != [ ]) {
    virtualisation.docker = {
      enable = true;
    };

    systemd.services = lib.foldl' (
      acc: c: acc // { "docker-${c.name}" = mkUnit c; }
    ) { } cfg.containers;
  };
}
