# Frigate NVR — 8 Hikvision cameras.
#
# WHY FRIGATE AND NOT SHINOBI
#
# Shinobi was the original intent. It was rejected on three findings:
#
#   * The `master` branch everyone installs is under a proprietary
#     source-available EULA, not GPL, and a 2025-02-13 commit added a
#     SOFTWARE-ENFORCED camera cap to unactivated installs. Free use also
#     requires displaying "shinobi.video" branding.
#   * ShinobiCE, the genuinely GPLv3 version, has been dead since 2021-02.
#   * Fatal to the actual requirement: Shinobi stores monitors/cameras and
#     users as DATABASE ROWS, creatable only through the web UI or authenticated
#     HTTP calls against a running instance. Only conf.json/super.json are
#     file-configurable, so "declarative cameras" would have meant a bespoke
#     imperative bootstrap script poking an HTTP API.
#
# Frigate is already packaged in nixpkgs with a NixOS module, is genuinely open
# source with no camera cap, and expresses cameras in its own config file —
# which the module exposes as `settings`, so the whole fleet's cameras are
# declared here and nowhere else.
#
# CREDENTIALS
#
# Camera credentials are NOT in this file, and must never be. `settings` is
# rendered to YAML in the Nix store, which is world-readable. Frigate resolves
# `{FRIGATE_*}` placeholders at runtime from either FRIGATE_-prefixed
# environment variables or FRIGATE_-prefixed FILES in $CREDENTIALS_DIRECTORY
# (see frigate/config/env.py). systemd LoadCredential= supplies the latter from
# sops, which is the same mechanism alertmanager and github-ci-exporter already
# use on sdrhub.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # ── Camera inventory ──────────────────────────────────────────────────────
  #
  # All eight are Hikvision on the LAN, verified 2026-08-10 by querying
  # /ISAPI/System/deviceInfo and /ISAPI/Streaming/channels on each, and by
  # ffprobing both RTSP channels of each over TCP.
  #
  #   7x DS-2CD2342WD-I (firmware V5.5.0)
  #     channel 101: 2688x1520 H.264 @20fps  (record)
  #     channel 102:  640x360  H.264 @15fps  (detect)
  #
  #   1x DB1 doorbell, 192.168.31.122 (firmware V1.4.62)
  #     channel 101: 1920x1080 H.264 @12fps  (record)
  #     channel 102:  640x480  H.264 @~3fps  (detect)
  #
  # The DB1 substream really does deliver ~3fps (24 frames in 8s, measured),
  # and reports maxFrameRate=0 over ISAPI rather than a real value. It gets its
  # own detect block below instead of the shared 640x360/5fps one.
  #
  # Names are the Frigate camera keys and appear in the UI, in MQTT topics and
  # in alert labels, so they are the snake_case form of the physical location
  # rather than the mangled BlueIris identifiers (`insidegaragemoti`) that the
  # previous NVR left on the disk.
  cameras = {
    front_door = {
      host = "192.168.31.237";
      detect = {
        width = 640;
        height = 360;
        fps = 5;
      };
    };
    doorbell = {
      host = "192.168.31.122";
      # DB1, not a DS-2CD2342WD-I: 4:3 substream and a much lower frame rate.
      detect = {
        width = 640;
        height = 480;
        fps = 3;
      };

      # The only camera with an audio stream, and it needs transcoding.
      #
      # The DB1 publishes h264 video + pcm_mulaw (G.711 µ-law) audio; the seven
      # DS-2CD2342WD-I units publish video only. MP4 has no tag for pcm_mulaw,
      # so copying it made ffmpeg fail the container header outright:
      #
      #   Could not find tag for codec pcm_mulaw in stream #1
      #   [out#0/segment] Could not write header (incorrect codec parameters ?)
      #
      # Every doorbell segment was then discarded ("Invalid or missing video
      # stream in segment ... Discarding") while the other seven recorded fine.
      # Observed on first deploy: 54 errors, all of them this camera.
      #
      # Transcoding to AAC rather than dropping audio with
      # `preset-record-generic` (-an): a doorbell is the one camera where audio
      # is actually worth having, and re-encoding 8 kHz mono G.711 to AAC is
      # negligible. Video is still stream-copied, so the expensive path is
      # untouched.
      recordPreset = "preset-record-generic-audio-aac";
    };
    garage_door = {
      host = "192.168.31.35";
      detect = {
        width = 640;
        height = 360;
        fps = 5;
      };
    };
    inside_garage = {
      host = "192.168.31.180";
      detect = {
        width = 640;
        height = 360;
        fps = 5;
      };
    };
    kitchen = {
      host = "192.168.31.87";
      detect = {
        width = 640;
        height = 360;
        fps = 5;
      };
    };
    living_room = {
      host = "192.168.31.18";
      detect = {
        width = 640;
        height = 360;
        fps = 5;
      };
    };
    office = {
      host = "192.168.31.15";
      detect = {
        width = 640;
        height = 360;
        fps = 5;
      };
    };
    upstairs_hall = {
      host = "192.168.31.10";
      detect = {
        width = 640;
        height = 360;
        fps = 5;
      };
    };
  };

  # Hikvision RTSP URL. Channel 101 is the main stream, 102 the substream.
  #
  # rtsp:// with credentials inlined is how Frigate consumes these; the
  # placeholders below are substituted at runtime from the sops-provided
  # credential files, so no secret is rendered into the store.
  mkStream =
    host: channel:
    "rtsp://{FRIGATE_CAMERA_USER}:{FRIGATE_CAMERA_PASSWORD}@${host}:554/Streaming/Channels/${toString channel}";

  mkCamera = _name: cam: {
    ffmpeg = {
      inputs = [
        # Substream drives detection. Decoding a 4MP stream 5x a second for
        # every camera is the single largest avoidable CPU cost in an NVR, and
        # these cameras already publish a 640x360 substream for exactly this.
        {
          path = mkStream cam.host 102;
          roles = [ "detect" ];
        }
        # Mainstream is recorded as-is: the bytes arrive already H.264 and are
        # stream-copied straight to disk, so recording costs almost no CPU.
        {
          path = mkStream cam.host 101;
          roles = [ "record" ];
        }
      ];

      # `preset-record-generic` (-an, no audio) is the default because seven of
      # the eight cameras publish no audio stream at all. Cameras that do carry
      # audio override this via `recordPreset` -- see the doorbell.
      #
      # Deliberately NOT `preset-record-generic-audio-copy` fleet-wide: that
      # copies whatever audio codec the camera offers, which breaks the MP4
      # container on any camera whose audio is not MP4-representable.
      output_args.record = cam.recordPreset or "preset-record-generic";
    };

    inherit (cam) detect;
  };
in
{
  services.frigate = {
    enable = true;

    # Served over plain HTTP on the LAN. The module only supports nginx, and
    # wires this vhost itself.
    hostname = "nvrhub.local";

    # Satisfy the build-time config validator.
    #
    # The module runs `frigate --validate-config` in the build sandbox, and
    # Frigate resolves `{FRIGATE_*}` placeholders while parsing. In the sandbox
    # there is no $CREDENTIALS_DIRECTORY and no FRIGATE_* environment, so the
    # real camera URLs raise `KeyError: 'FRIGATE_CAMERA_USER'` and the build
    # fails -- verified, this is not hypothetical.
    #
    # Exporting dummy values makes the placeholders resolvable so the validator
    # checks the parts that matter (stream roles, retention schema, detector,
    # detect geometry). These values exist only inside the sandbox; at runtime
    # systemd's LoadCredential= supplies the real secrets. Deliberately obvious
    # placeholders so a leak into a real config would be unmistakable.
    preCheckConfig = ''
      export FRIGATE_CAMERA_USER=validate-only
      export FRIGATE_CAMERA_PASSWORD=validate-only
    '';

    settings = {
      mqtt.enabled = false;

      # ── Detector ────────────────────────────────────────────────────────
      #
      # FIXME(frigate-openvino-yolox-detection-shape): this SHOULD be the openvino
      # detector with the yolox model packaged in frigate-model.nix. It is the
      # `cpu` (tflite) detector instead solely because YOLOX post-processing is
      # BROKEN in Frigate 0.17.2's OpenVINO plugin.
      #
      # The bug, in frigate/detectors/plugins/openvino.py (0.17.2):
      #
      #   detections = np.concatenate((image_pred[:, :5], class_conf,
      #                                class_pred), axis=1)   # 7 columns
      #   ordered = detections[...][:20]
      #   for i, object_detected in enumerate(ordered):
      #       detections[i] = self.process_yolo(...)          # returns 6 elems
      #   return detections                                   # 7-col array
      #
      # `process_yolo` returns [class_id, conf, y_min, x_min, y_max, x_max] --
      # six values -- but is assigned into a row of the seven-column working
      # array, and that array is then returned to a caller expecting (20, 6).
      # Both halves fail at runtime:
      #
      #   ValueError: could not broadcast input array from shape (6,) into shape (7,)
      #   ValueError: could not broadcast input array from shape (0,7) into shape (20,6)
      #
      # The same function in the memryx plugin is written correctly -- it
      # allocates `final_detections = np.zeros((20, 6), np.float32)` and writes
      # into that -- which confirms this is a copy-paste defect in the OpenVINO
      # path and not a misconfiguration here. Every other model type the
      # OpenVINO plugin supports (ssd, yolonas, yologeneric, rfdetr, dfine)
      # correctly produces (20, 6). Only yolox is affected, and it fails
      # unconditionally, so no config could avoid it.
      #
      # Symptom if this is reverted too early: the detector process crashes in
      # a loop, the watchdog logs "Detection appears to be stuck. Restarting
      # detection process..." then "Detection appears to have stopped. Exiting
      # Frigate...", and detection_fps stays 0 while recording keeps working.
      #
      # The `cpu` detector is a genuine downgrade in model quality
      # (ssdlite_mobiledet, 320x320) but it is CORRECT: tflite_detect_raw
      # allocates np.zeros((20, 6)) properly. It also needs no model config at
      # all -- nixpkgs patches ModelConfig's default path to the
      # ssdlite_mobiledet tflite it bundles, so omitting `model` entirely is
      # what makes this work.
      #
      # num_threads: 3 is the plugin default and is per-detector, not global.
      # Raised to 8 because this box has 16 threads and detection is the only
      # CPU-heavy work on it (recording is a stream copy).
      #
      # See .github/workflows/track-upstream-fixes.yaml -- when the upstream
      # fix lands, revert to the openvino/yolox block preserved in git history
      # and re-verify detection_fps > 0.
      detectors.cpu1 = {
        type = "cpu";
        num_threads = 8;
      };

      # Detection is OFF by default in Frigate 0.17.
      #
      # `DetectConfig.enabled` defaults to False, so setting only width/height/
      # fps per camera -- which looks like a complete detect block -- yields
      # cameras that decode their substream and then throw every frame away.
      # Confirmed via /api/stats: all eight reported
      #
      #   "camera_fps": 5.1, "process_fps": 5.1, "detection_fps": 0.0,
      #   "detection_enabled": false
      #
      # i.e. full frame ingest, zero inference. Set once at the top level so it
      # applies to every camera rather than being repeated (and forgotten) in
      # each per-camera block.
      detect.enabled = true;

      # ── Retention ───────────────────────────────────────────────────────
      #
      # Sized from a MEASURED bitrate, not a guess: 20s of the front-door
      # mainstream averaged 7.9 Mbps (VBR, 16 Mbps ceiling). That is ~85 GB per
      # camera per day, ~683 GB/day for all eight, against 3.5 TB usable.
      #
      # So continuous recording of everything is ~5.1 days and nothing else
      # fits. Hence the tiered policy:
      #
      #   * continuous 3 days  -- always able to scrub back over a long
      #     weekend, whether or not anything was detected.
      #   * alerts     30 days -- person/car, the events actually worth
      #     keeping.
      #   * detections 14 days -- everything the detector fired on.
      #
      # Worst case is 3 days of everything (~2.05 TB) plus 30 days of event
      # segments; events are a small fraction of wall-clock time, so this sits
      # comfortably inside 3.5 TB. Frigate expires the oldest segments itself
      # rather than filling the disk.
      record = {
        enabled = true;
        continuous.days = 3;
        alerts.retain.days = 30;
        detections.retain.days = 14;
      };

      # ── Objects ─────────────────────────────────────────────────────────
      #
      # person and car only. Adding pets roughly multiplies indoor events on
      # the kitchen/living-room cameras, and every extra event is retained
      # footage.
      objects.track = [
        "person"
        "car"
      ];

      snapshots.enabled = true;

      # Per-camera config, generated from the inventory above.
      cameras = lib.mapAttrs mkCamera cameras;
    };
  };

  systemd.services.frigate = {
    # Do not start the recorder unless the media disk is actually mounted.
    #
    # The /var/lib/frigate mount is `nofail` so a dead disk cannot strand this
    # headless box in an emergency shell. The consequence is that without this
    # guard Frigate would start regardless, StateDirectory= would CREATE
    # /var/lib/frigate on the root filesystem, and 8 cameras at ~7.9 Mbps would
    # fill the 465 GB root disk in under a day -- then mounting the media disk
    # later would hide that footage without deleting it.
    #
    # With this, the host always boots and stays monitored while the recorder
    # declines to run in a state where it would do damage.
    unitConfig.RequiresMountsFor = "/var/lib/frigate";

    serviceConfig = {
      # ── Credentials ───────────────────────────────────────────────────────
      #
      # The camera username/password are shared across all eight cameras and
      # live in sops. LoadCredential= hands the decrypted files to the unit;
      # Frigate reads $CREDENTIALS_DIRECTORY and substitutes the {FRIGATE_*}
      # placeholders.
      #
      # The credential names MUST be exactly the placeholder names -- Frigate
      # keys its substitution map on the FILENAME, and only considers files
      # whose name starts with FRIGATE_.
      LoadCredential = [
        "FRIGATE_CAMERA_USER:${config.sops.secrets."cameras/username".path}"
        "FRIGATE_CAMERA_PASSWORD:${config.sops.secrets."cameras/password".path}"
      ];

      # Drop stale detect shared-memory segments before starting.
      #
      # Frigate sizes one /dev/shm segment per camera as
      # model.width * model.height * 3 and creates it under
      # `except FileExistsError: pass`. Nothing ever resizes or removes an
      # existing segment, and /dev/shm survives a service restart
      # (PrivateTmp= does not cover it, and Frigate uses "untracked" shared
      # memory deliberately so segments outlive a crash).
      #
      # So ANY change to the model geometry leaves every camera pointing at a
      # wrongly-sized buffer, and each camera processor dies with
      #
      #   TypeError: buffer is too small for requested array
      #
      # while the service still reports active and keeps recording. Observed
      # here switching 320x320 -> 416x416: all eight segments stayed 307200
      # bytes from the previous generation and every camera process crashed on
      # startup. It cost a live debugging session to find, and it recurs on
      # every future model change (including the 416 -> 320 change that came
      # with the cpu-detector fallback above) unless handled automatically.
      #
      # Only the per-camera detect segments and their `out-` counterparts are
      # removed. The `<camera>_frameN` segments are the frame ring buffers,
      # sized from the camera's own detect resolution rather than the model's;
      # they are left alone so this does not become a blunt "wipe /dev/shm"
      # that fights Frigate for ownership of its own IPC.
      #
      # This APPENDS to the three ExecStartPre entries the upstream module
      # already defines (clear-cache, create-writable-config,
      # libavformat-major-version) -- verified by evaluating the merged list,
      # since replacing them would break config generation entirely.
      #
      # Safe to run unconditionally: the segments are pure IPC scratch space,
      # recreated on start, and the service is stopped when this executes.
      ExecStartPre = [
        (pkgs.writeShellScript "frigate-clear-stale-detect-shm" ''
          for cam in ${lib.escapeShellArgs (builtins.attrNames cameras)}; do
            rm -f "/dev/shm/$cam" "/dev/shm/out-$cam"
          done
        '')
      ];
    };
  };

  sops.secrets = {
    "cameras/username" = { };
    "cameras/password" = { };
  };

  # Expose Frigate's Prometheus metrics to the monitoring master.
  #
  # Frigate serves a native /api/metrics endpoint (frigate_camera_fps,
  # frigate_detection_fps, frigate_detector_inference_speed_seconds,
  # frigate_storage_*, ...), which the alert rules in
  # ../../../modules/monitoring/master/alert-rules/frigate-alerts.yaml consume.
  #
  # WHY THIS IS A TAILSCALE-FREE, OVERRIDE-FREE ONE-LINER
  #
  # /api/metrics requires authentication INSIDE Frigate, not merely in nginx.
  # In frigate/api/app.py the route is declared
  #
  #     @router.get("/metrics", dependencies=[Depends(allow_any_authenticated())])
  #
  # and allow_any_authenticated() raises 401 unless a `remote-user` request
  # header is present, with no config option to exempt it. Two earlier attempts
  # here failed because of that, and both are worth recording:
  #
  #   1. A location that BYPASSED nginx's auth_request. Cannot work: skipping
  #      the subrequest guarantees `remote-user` is absent, so Frigate 401s.
  #      Confirmed by curling Frigate's own port directly -- also 401. nginx is
  #      not the gatekeeper; Frigate is.
  #   2. Keeping auth_request but overriding X-Server-Port to 5000 in the /auth
  #      location, to reach Frigate's internal-port escape hatch:
  #
  #        # dont require auth if the request is on the internal port
  #        if int(request.headers.get("x-server-port", default=0)) == 5000:
  #            success_response.headers["remote-user"] = "anonymous"
  #
  #      The mechanism is real (verified: X-Server-Port 5000 -> 202 with
  #      remote-user: anonymous; 80 -> 401) but the override could not be made
  #      to stick. The upstream module already sets `proxy_set_header
  #      X-Server-Port $server_port` in that same location, and for duplicate
  #      proxy_set_header directives in one block nginx honours the FIRST, so an
  #      appended lib.mkAfter line is silently ignored.
  #
  # None of that is necessary. The upstream module ALREADY gives this vhost a
  # `listen 127.0.0.1:5000` (added for nixpkgs#370349, "Frigate wants to connect
  # on 127.0.0.1:5000 for unauthenticated requests"), and on that listener
  # $server_port genuinely IS 5000 -- so the module's own unmodified /auth
  # location takes the anonymous branch with no override at all.
  #
  # Verified on the running host: `curl 127.0.0.1:5000/api/metrics` returns 200
  # and 231 frigate_* series, while the same path on :80 returns 401.
  #
  # So the metrics endpoint needs no nginx changes whatsoever. What it needs is
  # for the scrape to originate ON nvrhub, which is what the node-local
  # textfile-free approach below does: Prometheus on sdrhub scrapes
  # nvrhub.local:9634, and a tiny local proxy relays to the loopback listener.
  # That keeps Frigate's auth fully intact for every other path and adds no
  # credential to manage.
  systemd.services.frigate-metrics-relay = {
    description = "Expose Frigate's loopback-only Prometheus metrics to the LAN";
    after = [
      "nginx.service"
      "frigate.service"
    ];
    wants = [ "nginx.service" ];
    wantedBy = [ "multi-user.target" ];

    # socat rather than another nginx vhost. A second nginx server block on
    # :9634 would have its own $server_port (9634), which puts it straight back
    # into the 401 case this whole comment exists to explain. A plain TCP relay
    # to 127.0.0.1:5000 preserves the port the AUTH decision is made on, because
    # the connection genuinely arrives at nginx on :5000.
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = "5s";
      DynamicUser = true;

      ExecStart = "${lib.getExe pkgs.socat} -d TCP-LISTEN:9634,fork,reuseaddr,bind=0.0.0.0 TCP:127.0.0.1:5000";

      # Hardening: this only ever moves bytes between two sockets.
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
      RestrictNamespaces = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" ];
    };
  };

  networking.firewall.allowedTCPPorts = [
    80 # nginx -> Frigate UI
    9634 # frigate-metrics-relay -> Prometheus on sdrhub
  ];
}
