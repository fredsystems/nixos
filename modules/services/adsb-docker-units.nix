{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.adsb;

  # A `ports` entry with fewer than 3 `:`-separated fields has no explicit
  # bind address ("HOSTPORT:CONTAINERPORT", or a range like
  # "9273-9274:9273-9274"), so Docker's `-p` falls back to its own default
  # of 0.0.0.0 -- reachable from anywhere the host itself is. That is fine
  # on every LAN-only host in this fleet, where "reachable from anywhere"
  # means "reachable from the LAN". On an internet-facing host it means
  # reachable from the internet, which is exactly the failure class
  # `deployment.internetFacing` exists to close for the exporters (see
  # modules/base/deployment-meta.nix) -- but that option only rebinds the
  # exporters it directly owns; a container port mapping written by hand in
  # a host config is not touched by it at all. fredvps had this exact
  # incident with dozzle-agent's default 0.0.0.0:7007 (see
  # modules/services/mk-dozzle-agent.nix's header) and every one of its
  # container ports is now bound to an explicit address, which is why this
  # warns rather than asserts: unlike internetFacing/tailscaleAddress, an
  # unbound port is not necessarily wrong (a deliberately public web UI would
  # look identical), so a human has to make the call.
  unboundPortsByContainer = lib.filterAttrs (_: bad: bad != [ ]) (
    lib.listToAttrs (
      map (c: {
        inherit (c) name;
        value = lib.filter (p: lib.length (lib.splitString ":" p) < 3) (c.ports or [ ]);
      }) cfg.containers
    )
  );

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

  # Common SDR device-access boilerplate, opt-in per container.
  #
  # `c 189:* rwm` is the USB char-device major number every SDR dongle on
  # these hosts (RTL-SDR, SDRplay RSP, Airspy) shows up under, and
  # `/run:exec,size=64M` is the writable+executable /run every one of those
  # decoders needs for its own PID file / control socket. Both were being
  # copy-pasted verbatim into every SDR container across sdrhub, hfdlhub1,
  # vdlmhub and acarshub.
  #
  # Deliberately opt-in (call mkSdrContainer instead of writing a plain
  # attrset) rather than folded into mkUnit's defaults: most containers on
  # these hosts are feeders, UIs and sidecars that never touch the hardware,
  # so applying this to every container would be wrong for the majority of
  # them.
  #
  # A container needing more than the defaults lists its own
  # `deviceCgroupRules` / `tmpfs` exactly as it would on a plain attrset --
  # mkSdrContainer appends them after the defaults rather than replacing
  # them, so e.g. `tmpfs = [ "/var/log" ]` here becomes
  # `[ "/run:exec,size=64M" "/var/log" ]` in the final container.
  #
  # Containers whose device access needs differ from this shape entirely
  # (ultrafeeder's /run tmpfs is 256M with different sibling mounts;
  # dump978's is a different path altogether) do not fit "defaults ++
  # extras" and are left as plain attrsets rather than forced through here.
  sdrDeviceCgroupRulesDefault = [ "c 189:* rwm" ];
  sdrTmpfsDefault = [ "/run:exec,size=64M" ];

  mkSdrContainer =
    c:
    c
    // {
      deviceCgroupRules = sdrDeviceCgroupRulesDefault ++ (c.deviceCgroupRules or [ ]);
      tmpfs = sdrTmpfsDefault ++ (c.tmpfs or [ ]);
    };

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

        # This hardens the WRAPPER unit, not the container it runs. The
        # unit's own process only ever shells out to
        # `docker run|pull|rm|stop` against the Docker socket -- the
        # container's isolation is Docker's own job and is untouched by
        # these settings. Because the wrapper does so little, it needs
        # almost no privilege of its own, which is the same reasoning
        # modules/services/python-venv-app.nix applies to its sandboxed
        # services.
        #
        # ProtectSystem=strict makes the filesystem read-only outside an
        # explicit allowlist. Connecting to an already-existing UNIX socket
        # does not itself require a writable mount, but ReadWritePaths is
        # listed anyway to be explicit and safe against any client-side
        # bind/reconnect behaviour. Path confirmed against this repo's own
        # rendered config (docker.socket's ListenStream), not assumed --
        # the daemon config here sets no `-H` override.
        ProtectSystem = "strict";
        ReadWritePaths = [ "/run/docker.sock" ];

        NoNewPrivileges = true;
        PrivateTmp = true;

        # Deliberately NOT set: PrivateNetwork (these units manage
        # networked containers) and User/Group (the wrapper needs whatever
        # ambient permissions grant access to the Docker socket, which is
        # root-only by default).

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
  options.services.adsb.mkSdrContainer = lib.mkOption {
    type = lib.types.raw;
    readOnly = true;
    internal = true;
    default = mkSdrContainer;
    description = ''
      Helper function, not configuration data: takes a container attrset
      (the same shape accepted by `services.adsb.containers`) and returns
      one with the common SDR `deviceCgroupRules` / `tmpfs` boilerplate
      merged in ahead of anything the caller supplies for those two keys.

      Usage in a host configuration:

        services.adsb.containers = [
          (config.services.adsb.mkSdrContainer {
            name = "dumphfdl-1";
            image = "...";
            tmpfs = [ "/var/log" "/tmp" ]; # appended after the SDR defaults
            volumes = [ "/dev:/dev" ];
          })
        ];

      Opt-in only: most containers on these hosts (feeders, UIs, sidecars)
      never touch SDR hardware, so this must never apply automatically.
      See the `mkSdrContainer` definition in this file for exactly what it
      merges and why some SDR containers (ultrafeeder, dump978) still use a
      plain attrset instead.
    '';
  };

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

        NOTE: a secret referenced here is referenced by PATH, and that path
        does not change when the secret's contents do. Editing the value in
        secrets.yaml therefore produces an identical unit and systemd will
        NOT restart the container -- it keeps running with the old
        environment. Declare the secret with `mkContainerSecret` from
        modules/services/mk-container-secret.nix so the restart is wired up;
        that file explains why the wiring cannot live in this module.

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

    warnings = lib.optionals config.deployment.internetFacing (
      lib.mapAttrsToList (
        name: bad:
        "services.adsb.containers: '${name}' publishes ${toString bad} with no explicit bind address "
        + "on an internet-facing host (deployment.internetFacing = true), so Docker binds 0.0.0.0 and "
        + "the port is reachable from the public internet. Bind it to an explicit address (e.g. "
        + "\${config.deployment.tailscaleAddress} or 127.0.0.1) unless it is meant to be public."
      ) unboundPortsByContainer
    );
  };
}
