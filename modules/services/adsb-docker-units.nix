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

        # Per-container journal filtering, opt-in via `logFilterPatterns`.
        #
        # This exists for containers whose upstream image has no log-level
        # control of its own. Piping ExecStart through grep was the obvious
        # alternative and was rejected: it would mean the wrapper unit no
        # longer execs docker directly.
        #
        # SCOPE, AND IT IS NARROWER THAN IT LOOKS.
        #
        # LogFilterPatterns is a journald directive. It governs what systemd
        # ingests from the unit's stdout, and nothing else. It therefore
        # affects:
        #
        #   * the journal, and so Loki, the alert rules and the Grafana
        #     dashboards, which all read `unit="docker-<name>.service"`.
        #
        # It does NOT affect:
        #
        #   * `docker logs <name>`, or anything reading it -- Dozzle, most
        #     notably. dockerd writes its own copy through its configured log
        #     driver, independently of the journal, and journald cannot filter
        #     a stream it never sees.
        #
        # So a filtered container still shows its full output in Dozzle. That
        # was verified the hard way after this landed: the dict lines were gone
        # from the journal (0 in a 2-minute window) while still visible in
        # Dozzle, because the two streams are genuinely separate. Do not
        # describe this as dropping lines "before they are written" -- it drops
        # them before *journald* writes them, which is where the write
        # amplification this is aimed at actually occurs.
        #
        # One further documented limitation: filtering applies to the unit's
        # own log stream, not to messages systemd emits *about* the unit, so
        # start/stop/failure records are always preserved.
        LogFilterPatterns = c.logFilterPatterns or [ ];

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
      - `logFilterPatterns` -- list of systemd `LogFilterPatterns=` entries,
        applied to this container's journal stream. A pattern prefixed with
        `~` is a deny pattern.

        Affects the journal only, and therefore Loki, the alert rules and the
        dashboards. It does NOT affect `docker logs` or Dozzle, which read
        dockerd's own separate copy -- see the longer note in `mkUnit`. A
        filtered container still shows everything in Dozzle.

        Use this only for images with no log-level control of their own, and
        prefer fixing the application when that is an option: a filter here
        treats the symptom on one host, while the upstream image keeps
        emitting the same volume everywhere else it runs.

      Anything else is a no-op. Add it here and to `mkUnit` if it is needed.
    '';
  };

  config = lib.mkIf (cfg.containers != [ ]) {
    virtualisation.docker = {
      enable = true;

      # Every container's output was being written to the journal TWICE.
      #
      # Measured on sdrhub 2026-08-18. All entries at a single timestamp, for
      # one 80-line burst from acars2pos:
      #
      #   81 lines  from  docker          <- this unit's stdout
      #   81 lines  from  7acfceb5aa97    <- same content, dockerd's log driver
      #
      # 162 journal entries for 81 lines of application output.
      #
      # The cause is structural, not per-container: mkUnit runs `docker run`
      # WITHOUT -d, so the wrapper unit stays attached to the container's
      # stdout for its whole lifetime and systemd captures it as
      # docker-<name>.service output. Meanwhile dockerd's own logDriver
      # (journald, the NixOS default -- see the correction in
      # AUDIT-2026-08-04.md Part 3) independently wrote the identical lines a
      # second time. Two writers, same bytes.
      #
      # That doubled journald write amplification, Loki ingestion, and 30 days
      # of Loki storage, on all six container hosts.
      #
      # WHY THE DOCKERD COPY IS THE ONE THAT GOES
      #
      # This direction is load-bearing and was verified before changing it,
      # because the intuitive choice is wrong. The two copies are NOT
      # interchangeable:
      #
      #   * The wrapper copy lands as unit="docker-<name>.service". NINE Loki
      #     alert rules select on `unit=~"docker-.*"`
      #     (modules/monitoring/master/loki-ruler.nix) -- DecoderS6Caution,
      #     UsbClaimInterface, SdrPlayServiceNotResponding, the decoder
      #     message-rate rules -- and the "Container Logs" panel in
      #     dashboards/system-logs.json queries the same selector.
      #   * The dockerd copy lands as unit="docker.service", with nothing
      #     selecting on it anywhere in this repo.
      #
      # Suppressing the wrapper copy instead would therefore have silently
      # disabled nine alerts. Nothing would have caught it either:
      # scripts/check-alert-metrics.sh validates Prometheus metrics, and these
      # are Loki rules.
      #
      # Note also that alloy's `_CONTAINER_NAME` -> `container` relabel
      # (modules/monitoring/agent/alloy.nix) yields nothing in practice --
      # Loki's own /labels endpoint lists no `container` label at all -- so the
      # dockerd copy's supposed advantage of carrying container metadata does
      # not actually materialise. Verified against the live instance.
      #
      # Confirmed before landing that every container has a wrapper stream in
      # Loki (all 31 docker-*.service units present), including xng and
      # radarvirtuel, which had appeared only under docker.service in a
      # narrower sample.
      #
      # `local` rather than `none`: it keeps `docker logs <name>` working for
      # interactive debugging, which `none` would break. It is capped, unlike
      # the json-file default, so it cannot become the disk filler that the
      # audit rejected log-opts for. Container output still reaches the
      # journal, and therefore Loki, via the wrapper unit.
      # Set via the module's own logDriver option rather than
      # daemon.settings.log-driver. Both work -- the module renders
      # `log-driver = mkDefault cfg.logDriver`, so an explicit
      # daemon.settings entry would override it -- but having the two disagree
      # makes `config.virtualisation.docker.logDriver` report "journald" on a
      # host that is not using it, which is exactly the kind of
      # stated-versus-actual gap this repo keeps getting bitten by.
      logDriver = "local";

      # log-opts is only honoured by the json-file and local drivers, which is
      # why the audit rejected it while the driver was journald
      # (AUDIT-2026-08-04.md, "Items to not re-propose"). That rejection was
      # correct then and is now superseded: under `local` these are live, and
      # they are what keeps this from becoming the disk filler the audit was
      # right to worry about.
      #
      # 30 MB retained per container (10m x 3), and note this is a per-container
      # budget rather than the host-wide one journald imposes. That is a
      # meaningful improvement on its own: under the journald driver every
      # container competed for the single 1 GB SystemMaxUse pool, so one chatty
      # container shortened everyone else's retention -- the residual recorded
      # as item 6.11 in AUDIT-2026-08-04.md. It cannot now.
      #
      # On scrollback depth: rotated files are gzipped by the local driver, so
      # only the active container.log is uncompressed and effective retention
      # is longer than dividing 30 MB by an observed byte rate suggests. Any
      # such estimate is also biased low if measured shortly after a deploy --
      # these images dump a burst of startup output and then go comparatively
      # quiet, so a sample taken in the first minutes overstates the steady-state
      # rate considerably.
      #
      # Loki remains the archive at 30 days, queryable by
      # unit="docker-<name>.service". `docker logs` / Dozzle is the live-tail
      # view. Raise max-size here if deeper interactive scrollback is wanted;
      # there is no space pressure on any of these hosts.
      daemon.settings.log-opts = {
        max-size = "10m";
        max-file = "3";
      };
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
