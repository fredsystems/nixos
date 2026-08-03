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

      # Without --hostname a container's hostname is its container id, and
      # anything inside that self-identifies picks that up. That is not
      # cosmetic: telegraf in the dump978 container tagged every metric with
      # host=<container id>, which changes on each recreate, so the Prometheus
      # job needs a labeldrop to avoid churning its entire series set. Four
      # containers already set `hostname` expecting it to be honoured.
      hostnameFlag = lib.optionalString (c ? hostname) ''--hostname "${c.hostname}"'';

      # Ordering against sibling containers. Several entries previously carried
      # Docker Compose's `depends_on = { name = { condition = ...; }; }`, which
      # this module never read, so the units started in parallel regardless.
      # Expressed here as a plain list of container names and translated to
      # systemd ordering.
      #
      # After= on a Type=simple unit waits for the process to be spawned, which
      # is the same guarantee Compose's `service_started` gives. Ordering only,
      # deliberately not Requires=: a sibling decoder failing should not stop
      # the others from running.
      dependsOnUnits = map (n: "docker-${n}.service") (c.dependsOn or [ ]);
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
          + " ${hostnameFlag} ${ttyFlag} ${deviceRuleFlags} ${deviceFlags} ${envFlags} ${envFileFlags} ${volumeFlags} ${tmpfsFlags} ${portFlags} "
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
      ]
      ++ dependsOnUnits;
      wants = [ "network-online.target" ];
    };
in
{
  options.services.adsb.containers = lib.mkOption {
    type = lib.types.listOf lib.types.attrs;
    default = [ ];
    description = ''
      List of ADS-B/ACARS/SDR containers to run under Docker.

      The type is a freeform `listOf attrs`, so a key that this module does not
      read is silently ignored rather than rejected. Three keys were being set
      with no effect before this was documented: `hostname` and `depends_on`
      (both now honoured, the latter renamed to `dependsOn`) and `requires`,
      whose intent was already covered by the `wants`/`after` on
      network-online.target that every unit gets.

      Recognised keys:

      - `name`, `image` (required)
      - `hostname` -- passed as `docker run --hostname`
      - `dependsOn` -- list of sibling container names; becomes systemd
        `After=docker-<name>.service`, ordering only
      - `environment` (attrset), `environmentFiles` (list of paths)
      - `volumes`, `tmpfs`, `ports` (lists)
      - `devices`, `deviceCgroupRules` (lists)
      - `restart` (default "always"), `exec`, `tty`, `extraDockerArgs`

      Anything else is a no-op. Add it here and to `mkUnit` if it is needed.
    '';
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
