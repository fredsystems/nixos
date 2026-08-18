# Frigate NVR — 7 cameras: 5 Hikvision + 2 Reolink.
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
  # Five Hikvision, verified 2026-08-10 by querying /ISAPI/System/deviceInfo
  # and /ISAPI/Streaming/channels on each, and by ffprobing both RTSP channels
  # of each over TCP.
  #
  #   5x DS-2CD2342WD-I (firmware V5.5.0)
  #     channel 101: 2688x1520 H.264 @20fps  (record)
  #     channel 102:  640x360  H.264 @15fps  (detect)
  #
  # A sixth DS-2CD2342WD-I covered the garage door at 192.168.31.35 and is
  # TEMPORARILY REMOVED (2026-08-18) while the camera is offline — see the
  # note where its block used to be, below.
  #
  # One Reolink doorbell, which REPLACED the Hikvision DB1 that used to sit at
  # 192.168.31.122. Verified 2026-08-17 against the device itself via its
  # /cgi-bin/api.cgi GetDevInfo + GetEnc endpoints and by ffprobing both RTSP
  # paths over TCP:
  #
  #   1x Reolink D340W "Video Doorbell WiFi", 192.168.31.27
  #     hardVer DB_566128M5MP_W, firmware v3.0.0.4662_2508071282
  #     h264Preview_01_main: 2560x1920 H.264 High @20fps + AAC LC 16 kHz mono
  #     h264Preview_01_sub:   640x480  H.264 High @10fps + AAC LC 16 kHz mono
  #
  # Strictly better than the DB1 it replaced on every axis that matters here:
  # 4.9 MP vs 2.1 MP recorded, 20fps vs 12fps recorded, and a substream that
  # delivers a real 10fps (101 frames in 10.1s, measured) against the DB1's
  # ~3fps. It is the only 4:3 substream in the fleet, so like the DB1 it keeps
  # its own detect block rather than sharing the 640x360 one.
  #
  # NOTE FOR THE NEXT REOLINK: this camera was unreachable on first contact
  # because current Reolink firmware ships with HTTP, HTTPS, RTSP, RTMP and
  # ONVIF all DISABLED — only the proprietary port 9000 answers, and it resets
  # non-Reolink clients. RTSP must be switched on by hand in the Reolink app
  # (Device Settings -> Network -> Advanced -> Port Settings) before Frigate can
  # see anything. There is no way to do that declaratively from here.
  #
  # Names are the Frigate camera keys and appear in the UI, in MQTT topics and
  # in alert labels, so they are the snake_case form of the physical location
  # rather than the mangled BlueIris identifiers (`insidegaragemoti`) that the
  # previous NVR left on the disk.
  cameras = {
    # Reolink E1 Outdoor SE PoE, which REPLACED the Hikvision DS-2CD2342WD-I
    # that used to sit at 192.168.31.237. Verified 2026-08-18 against the device
    # via /cgi-bin/api.cgi GetDevInfo + GetEnc and by ffprobing its RTSP paths
    # over TCP:
    #
    #   192.168.31.38, hardVer IPC_NT2NA48MPSD8V3
    #   firmware v3.1.0.5223_2510172104
    #   h265Preview_01_main: 3840x2160 HEVC Main @25fps + AAC LC 16 kHz mono
    #   h264Preview_01_sub:   640x360  H.264 High @10fps + AAC LC 16 kHz mono
    #
    # This is the only H.265 camera in the fleet, hence `codec = "h265"` — see
    # the streamPaths comment for why that is a separate dimension from `brand`.
    #
    # Its substream is a conventional 640x360, so unlike the 4:3 doorbell it
    # uses the same detect geometry as the Hikvisions. detect.fps stays at the
    # fleet's 5 even though the substream delivers 10, for the same
    # shared-CPU-detector reason documented on the doorbell.
    #
    # Only camera in the fleet with PTZ — see `ptz` below.
    front_door = {
      brand = "reolink";
      codec = "h265";
      host = "192.168.31.38";

      # ── Manual pan/tilt over ONVIF ──────────────────────────────────────
      #
      # Presence of `ptz` is what enables the ONVIF block; the port is carried
      # here rather than as a separate bool so there is no way to enable PTZ
      # without stating which port it speaks on. 8000 is verified open on this
      # camera and is also Frigate's OnvifConfig default, but Hikvision ONVIF
      # answers on 80, so the next PTZ camera must state its own.
      #
      # WHAT WORKS: pan and tilt from the UI. Frigate derives its feature list
      # from the PTZ node's supported spaces (ptz/onvif.py:347-430), and this
      # camera advertises ContinuousPanTiltVelocitySpace, which is what yields
      # the `pt` feature.
      #
      # WHAT DOES NOT, and why autotracking is deliberately left OFF (it
      # defaults to false; this is documentation, not configuration). Read off
      # the camera's own PTZ node via GetNodes, verified 2026-08-18:
      #
      #   ContinuousPanTiltVelocitySpace : yes  -> feature "pt"
      #   RelativePanTiltTranslationSpace: no   -> NO feature "pt-r-fov"
      #   AbsolutePanTiltPositionSpace   : no
      #   ContinuousZoomVelocitySpace    : no   -> NO feature "zoom"
      #   HomeSupported                  : False
      #   GetStatus -> Position          : None
      #
      # ptz/onvif.py:419-424 only appends "pt-r-fov" when
      # DefaultRelativePanTiltTranslationSpace exists, and autotrack.py:274-279
      # then does:
      #
      #   if "pt-r-fov" not in features:
      #       "Disabling autotracking for {camera}: FOV relative movement
      #        not supported"
      #       camera_config.onvif.autotracking.enabled = False
      #
      # So setting autotracking.enabled = true here would log a warning on every
      # start and turn itself straight back off. `Position: None` and
      # `HomeSupported: False` rule it out independently — autotracking needs
      # position feedback to know where it is and a home preset to return to.
      #
      # Zoom is absent over ONVIF despite Reolink's own API reporting
      # `supportZoom`, because on an E1 Outdoor SE the zoom is DIGITAL. Nothing
      # to configure; the UI simply will not offer a zoom control.
      #
      # Preset recall is wired up but close to useless until presets are created
      # in the Reolink app: GetPresets returns exactly one (token '000', name
      # '0') against a MaximumNumberOfPresets of 64. `return_preset` is
      # untouched for the same reason — its default is "home", which this camera
      # does not have.
      #
      # `ignore_time_mismatch` is deliberately NOT set. ONVIF auth is
      # timestamp-sensitive, so it was measured rather than guessed: the camera
      # reports DateTimeType NTP and a skew of -4.7s against this host, well
      # inside any tolerance. Set it only if ONVIF auth actually starts failing.
      ptz.port = 8000;
      detect = {
        width = 640;
        height = 360;
        fps = 5;
      };

      # Second camera with audio. It publishes AAC LC directly, exactly like the
      # doorbell, so both streams are stream-copied and recording costs
      # essentially no CPU despite being 4K. Verified rather than assumed: 10s of
      # the mainstream muxed with `ffmpeg -c copy -f mp4` produced hev1 + mp4a
      # with no header error.
      #
      # NOTE: 4K HEVC records correctly but may not PLAY BACK in a browser —
      # Firefox and Chrome have no software HEVC decoder. If the Frigate UI shows
      # black for this camera's recordings, that is why, and the fix is to switch
      # the camera's mainStream vType to h264 (GetEnc action=1 reports both
      # "h264" and "h265" are supported) and drop the `codec` line above.
      recordPreset = "preset-record-generic-audio-copy";
    };
    doorbell = {
      brand = "reolink";

      # Genuinely H.264, unlike the front door's HEVC — ffprobe-verified against
      # h264Preview_01_main (avc1 in the muxed MP4).
      codec = "h264";
      host = "192.168.31.27";

      # 4:3 substream, so not the shared 640x360 block.
      #
      # width/height MUST equal the substream's real resolution -- Frigate uses
      # them as frame_shape to slice the raw yuv420p byte stream, so a mismatch
      # yields sheared garbage rather than an error. 640x480 is ffprobe-verified
      # against h264Preview_01_sub. Omitting them entirely would also work
      # (Frigate probes the stream at config.py:534-555) and would arrive at the
      # same numbers; they are stated so the inventory above is checkable.
      #
      # Not adjustable in any case: GetEnc reports the substream `size` as a
      # bare "640*480" string, unlike `bitRate`/`frameRate` which come back as
      # lists of options. Detecting on more pixels would mean pointing the
      # detect role at the 2560x1920 mainstream, which is the exact cost the
      # substream split exists to avoid.
      #
      # fps is 5 rather than the 10 the substream actually delivers: every other
      # camera detects at 5, the detector is a single shared CPU
      # detector, and Frigate downsamples the decode to detect.fps anyway.
      # Frigate itself warns above 10 and recommends 5 (config.py:559). The
      # DB1's 3 was a hardware ceiling; this 5 is a choice, so it can be raised
      # to 10 if doorbell detection latency ever matters more than CPU.
      detect = {
        width = 640;
        height = 480;
        fps = 5;
      };

      # No longer needs transcoding (and no longer the only camera with audio —
      # the Reolink front door has it too).
      #
      # The DB1 published pcm_mulaw (G.711 µ-law), which MP4 has no tag for, so
      # copying it failed the container header outright:
      #
      #   Could not find tag for codec pcm_mulaw in stream #1
      #   [out#0/segment] Could not write header (incorrect codec parameters ?)
      #
      # Every doorbell segment was then discarded ("Invalid or missing video
      # stream in segment ... Discarding") while every other camera recorded
      # fine — 54 errors on first deploy, all of them that camera. Hence the old
      # `preset-record-generic-audio-aac`, which re-encoded to AAC.
      #
      # The D340W publishes AAC LC directly, so the transcode is pure waste.
      # `-audio-copy` is `-c copy` with no `-an`, i.e. BOTH streams are
      # stream-copied and this camera now costs the same CPU to record as the
      # video-only ones. Verified rather than assumed: 20s of the mainstream
      # muxed with `ffmpeg -c copy -f mp4` produced avc1 + mp4a with no header
      # error.
      recordPreset = "preset-record-generic-audio-copy";
    };
    # ── garage_door: TEMPORARILY REMOVED 2026-08-18 ───────────────────────
    #
    # DS-2CD2342WD-I at 192.168.31.35, offline for a few days. To restore it,
    # re-add:
    #
    #   garage_door = {
    #     brand = "hikvision";
    #     host = "192.168.31.35";
    #     detect = { width = 640; height = 360; fps = 5; };
    #   };
    #
    # WHY THE ENTRY IS DELETED RATHER THAN `enabled = false`
    #
    # Setting `enabled = false` would NOT have stopped the alerts, and would in
    # fact have made them permanent. Frigate 0.17.2 registers metrics for every
    # camera in the config regardless of `enabled`:
    #
    #   * app.py:143-145 init_camera_metrics() loops config.cameras.keys() with
    #     no enabled check, creating a CameraMetrics for each.
    #   * CameraMetrics.__init__ (camera/__init__.py:24) inits camera_fps to 0.
    #   * camera/maintainer.py:98,149 then SKIP starting the processor and
    #     capture process for a disabled camera, so nothing ever writes a
    #     nonzero value.
    #   * stats/util.py:269 iterates camera_metrics.items() and
    #     stats/prometheus.py:84 exports every entry.
    #
    # So a disabled camera publishes frigate_camera_fps == 0 forever, and
    # FrigateCameraNoFrames (`frigate_camera_fps == 0 for 10m`, see
    # ../../../modules/monitoring/master/alert-rules/frigate-alerts.yaml) fires
    # continuously instead of transiently. Removing the key is the only thing
    # that stops the series being emitted at all.
    #
    # Existing footage is NOT destroyed by this. record/cleanup.py:287 deletes
    # recordings for cameras `not_in config.cameras.keys()` only where
    # `end_time < expire_before`, i.e. already past the 3-day continuous
    # retention. The garage's recent recordings therefore age out normally
    # rather than being purged on the next cleanup run.
    inside_garage = {
      brand = "hikvision";
      host = "192.168.31.180";
      detect = {
        width = 640;
        height = 360;
        fps = 5;
      };
    };
    kitchen = {
      brand = "hikvision";
      host = "192.168.31.87";
      detect = {
        width = 640;
        height = 360;
        fps = 5;
      };
    };
    living_room = {
      brand = "hikvision";
      host = "192.168.31.18";
      detect = {
        width = 640;
        height = 360;
        fps = 5;
      };
    };
    office = {
      brand = "hikvision";
      host = "192.168.31.15";
      detect = {
        width = 640;
        height = 360;
        fps = 5;
      };
    };
    upstairs_hall = {
      brand = "hikvision";
      host = "192.168.31.10";
      detect = {
        width = 640;
        height = 360;
        fps = 5;
      };
    };
  };

  # RTSP paths per brand, keyed by the Frigate role that consumes them.
  #
  # This used to be a single hardcoded Hikvision path with the channel number
  # interpolated (101 main / 102 sub). Reolink does not expose channels that
  # way at all — it names the streams — so the path is now a per-brand lookup
  # instead of a per-camera number.
  #
  # `cameras.<name>.brand` is indexed into this attrset with NO default, which
  # is the point: a missing or misspelled brand is an evaluation error at build
  # time. Defaulting to hikvision would let the next Reolink silently inherit
  # /Streaming/Channels/10x paths and fail only once deployed, as a stream that
  # never connects.
  #
  # WHY REOLINK'S RECORD PATH IS BUILT FROM `codec`
  #
  # Reolink names its mainstream after a codec, and the fleet now contains one
  # of each: the doorbell's mainstream is genuinely H.264 while the front door's
  # is HEVC. So the path cannot be a constant.
  #
  # Do NOT assume the name in the path selects the codec — it does not. On the
  # E1 Outdoor SE, `h264Preview_01_main` and `h265Preview_01_main` BOTH return
  # the same 4K HEVC stream (ffprobe-verified on all four combinations); the
  # camera serves whatever its mainStream vType is set to and ignores the name.
  # The name is therefore documentation, and `codec` exists to keep that
  # documentation honest rather than to change what the camera sends. Getting it
  # wrong yields a working stream that lies about its codec, which is exactly
  # how the 4K HEVC front door would otherwise have been mistaken for H.264.
  #
  # `cam.codec` is indexed with no default for the same reason `brand` is: a
  # Reolink added without one is an eval error, not a silent wrong guess.
  #
  # Substreams are H.264 on both Reolinks regardless of the mainstream setting
  # (the E1's GetEnc reports subStream vType h264 while mainStream is h265), so
  # the detect path is constant.
  streamPaths = {
    hikvision = _cam: {
      detect = "Streaming/Channels/102";
      record = "Streaming/Channels/101";
    };
    reolink = cam: {
      detect = "h264Preview_01_sub";
      record = "${cam.codec}Preview_01_main";
    };
  };

  # rtsp:// with credentials inlined is how Frigate consumes these; the
  # placeholders below are substituted at runtime from the sops-provided
  # credential files, so no secret is rendered into the store.
  #
  # All seven cameras share one credential pair, including both Reolinks — their
  # admin accounts were set to the same username/password as the Hikvisions
  # rather than adding a second sops secret and a second LoadCredential entry.
  mkStream =
    cam: role:
    "rtsp://{FRIGATE_CAMERA_USER}:{FRIGATE_CAMERA_PASSWORD}@${cam.host}:554/${
      (streamPaths.${cam.brand} cam).${role}
    }";

  mkCamera =
    _name: cam:
    {
      ffmpeg = {
        inputs = [
          # Substream drives detection. Decoding a 4MP stream 5x a second for
          # every camera is the single largest avoidable CPU cost in an NVR, and
          # every one of these cameras already publishes a low-resolution
          # substream for exactly this.
          {
            path = mkStream cam "detect";
            roles = [ "detect" ];
          }
          # Mainstream is recorded as-is: the bytes arrive already H.264 and are
          # stream-copied straight to disk, so recording costs almost no CPU.
          {
            path = mkStream cam "record";
            roles = [ "record" ];
          }
        ];

        # `preset-record-generic` (-an, no audio) is the default because the five
        # Hikvisions publish no audio stream at all. Cameras that do carry audio
        # override this via `recordPreset` -- see the doorbell and front door.
        #
        # Deliberately NOT `preset-record-generic-audio-copy` fleet-wide: that
        # copies whatever audio codec the camera offers, which breaks the MP4
        # container on any camera whose audio is not MP4-representable.
        output_args.record = cam.recordPreset or "preset-record-generic";
      };

      inherit (cam) detect;
    }
    # ONVIF block, emitted only for cameras that declare `ptz`. Frigate gates the
    # whole PTZ subsystem on `onvif.host` being non-empty (ptz/onvif.py:64), so
    # omitting the block entirely — rather than emitting an empty one — is what
    # keeps the six non-PTZ cameras out of it.
    #
    # host and credentials are derived rather than repeated per camera: the
    # placeholders are the SAME ones used for the RTSP URLs, and they work here for
    # the same reason. OnvifConfig.user/password are typed EnvString
    # (config/camera/onvif.py:76-78), and validate_env_string (config/env.py:18-23)
    # runs `.format(**FRIGATE_ENV_VARS)` on every EnvString field, where
    # FRIGATE_ENV_VARS is populated from FRIGATE_-prefixed files in
    # $CREDENTIALS_DIRECTORY. So the existing LoadCredential= pair covers ONVIF
    # too, and no second sops secret is needed. preCheckConfig's dummy exports
    # likewise make these resolvable in the build sandbox.
    // lib.optionalAttrs (cam ? ptz) {
      onvif = {
        inherit (cam) host;
        inherit (cam.ptz) port;
        user = "{FRIGATE_CAMERA_USER}";
        password = "{FRIGATE_CAMERA_PASSWORD}";
      };
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
      # Confirmed via /api/stats: every camera reported
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
      # Sized from MEASURED bitrates, not guesses. Per camera per day, against
      # 3.5 TB usable:
      #
      #   5x Hikvision DS-2CD2342WD-I  7.9 Mbps  ~85 GB  = ~425 GB
      #   1x Reolink D340W doorbell    4.39 Mbps ~47 GB  =  ~47 GB
      #   1x Reolink E1 front door     6.21 Mbps ~67 GB  =  ~67 GB
      #                                                  ---------
      #                                                   ~539 GB/day
      #
      # The Hikvision figure is 20s of mainstream at VBR with a 16 Mbps ceiling.
      # Neither Reolink disturbs it despite recording more pixels, because both
      # cap their mainstream bitrate: the doorbell at 4096 kbps (4.39 Mbps
      # measured) and the front door at 6144 kbps (6.21 Mbps measured over 10s).
      # The 4K HEVC front door is therefore CHEAPER per day than any Hikvision —
      # H.265 at a capped bitrate buys resolution, not bytes.
      #
      # So continuous recording of everything is ~6.5 days and nothing else
      # fits. Hence the tiered policy:
      #
      #   * continuous 3 days  -- always able to scrub back over a long
      #     weekend, whether or not anything was detected.
      #   * alerts     30 days -- person/car, the events actually worth
      #     keeping.
      #   * detections 14 days -- everything the detector fired on.
      #
      # Worst case is 3 days of everything (~1.62 TB) plus 30 days of event
      # segments; events are a small fraction of wall-clock time, so this sits
      # comfortably inside 3.5 TB. Frigate expires the oldest segments itself
      # rather than filling the disk.
      #
      # Note this is currently one camera light: garage_door is temporarily
      # removed, so restoring it adds ~85 GB/day back. The figures above already
      # exclude it, so it is the 6.5-day headroom that shrinks, not the policy.
      record = {
        enabled = true;
        continuous.days = 3;
        alerts.retain.days = 30;
        detections.retain.days = 14;
      };

      # ── Objects ─────────────────────────────────────────────────────────
      #
      # Every label here must exist in the ACTIVE MODEL'S labelmap, which for
      # the bundled ssdlite_mobiledet is the 91-class COCO map at
      # <frigate>/share/frigate/labelmap.txt. Swapping the detector swaps the
      # labelmap, so this list is coupled to the model -- see the 80-vs-91-class
      # hazard noted in the alert rules.
      #
      # NOTE there is no "truck" in that map. Delivery vans and pickups
      # therefore classify as "car", which is why adding a truck entry here
      # would silently never match.
      #
      # COST OF EACH ADDITION. Tracking more classes does NOT make an
      # individual inference more expensive -- the model already emits all 90
      # classes and this list only filters them. It costs CPU indirectly:
      # every tracked object gets its own detector region every frame, so more
      # matched classes means more regions, which is the same mechanism
      # currently pinning the two Reolinks at ~200%. It also costs disk, since
      # every extra event is retained footage.
      #
      # Pets were deliberately excluded when this was first written, on the
      # grounds that they multiply indoor events on the kitchen and living-room
      # cameras. That is still true and is accepted here as the price of
      # actually recording the dog; if indoor event volume becomes a problem,
      # dog/cat are the first things to drop.
      #
      # DELIBERATELY NOT TRACKED, despite being in the labelmap:
      #
      #   bird                  Constant outdoor false triggers, which is the
      #                         exact failure mode being fought elsewhere in
      #                         this file.
      #   umbrella, backpack,   Only ever co-occur with a person who is already
      #   handbag, suitcase     tracked, so they add regions and events without
      #                         adding information. `backpack`/`suitcase` are
      #                         tempting for porch-piracy detection, but the
      #                         courier logos in DEFAULT_ATTRIBUTE_LABEL_MAP
      #                         (amazon, fedex, dhl, ups, ...) already attach to
      #                         the parent person/car as ATTRIBUTES and cannot
      #                         be tracked as objects here anyway.
      #
      # RETENTION INTERACTION: review.alerts.labels is [person, car], so only
      # those two produce 30-day alerts. Everything added below lands in the
      # 14-day detections tier instead. That is deliberate -- promoting pets or
      # bicycles to alerts would inflate the 30-day tier.
      objects = {
        track = [
          "person"
          "car"
          "motorcycle"
          "bicycle"
          "bus"
          "dog"
          "cat"
        ];

        # ── EXPERIMENT 2026-08-18: car detection-confidence floor ──────────
        #
        # TEMPORARY. Revert this filter (delete the whole `filters` block) once
        # the detector question below is settled either way.
        #
        # THE PROBLEM THIS TESTS
        #
        # The two outdoor Reolinks burn ~200% CPU EACH in their camera tracker
        # processes, against 0-24% for every indoor Hikvision. Measured from
        # /api/stats:
        #
        #   doorbell    cam_proc 194%   detection_fps 21.3
        #   front_door  cam_proc 208%   detection_fps 22.6
        #   (every Hikvision)           detection_fps 0.0 - 5.0
        #
        # At camera_fps 5 that is ~4.4 detector regions per frame, sustained
        # forever, and it is what triggers Frigate's "has high detect CPU usage"
        # banner (web/src/hooks/use-stats.ts:112, threshold 40%).
        #
        # ROOT CAUSE
        #
        # A car parked on the street. It produced 101 SEPARATE car events on
        # doorbell (durations 1s..731s) when one parked car should produce one.
        # Scores across those events:
        #
        #   min 0.512   max 0.770   mean 0.668
        #
        # FilterConfig.threshold (config/camera/objects.py:30) defaults to 0.7
        # and is the AVERAGE detection confidence required for an object to be
        # counted -- not the per-frame minimum, which is min_score (0.5). The
        # car's average of 0.668 sits just under 0.7, so it is repeatedly
        # counted, dropped, and re-acquired. Because it never holds a stable
        # track it never reaches the `stationary` state, so it never drops to
        # the cheap re-check path (detect.stationary.interval, 50 frames) and
        # instead gets a fresh region EVERY frame.
        #
        # 0.6 is chosen to sit below the measured 0.668 mean but comfortably
        # above the 0.512 floor, and above min_score so the two still compose.
        # Set globally rather than per-camera because the indoor cameras see
        # essentially no cars, so the blast radius is the two that matter.
        #
        # HOW TO READ THE RESULT
        #
        # If the theory holds, after deploying THIS COMMIT ALONE:
        #
        #   frigate_detection_fps{camera_name="doorbell"}   22 -> near 0
        #   frigate_detection_fps{camera_name="front_door"} 23 -> near 0
        #   the two cam_proc figures fall well under 40%
        #   the UI banner stops
        #
        # That would confirm the churn mechanism and prove a better detection
        # model is the real fix (a stronger model scores this car ~0.9 and it
        # latches without needing a lowered threshold). If detection_fps does
        # NOT fall, the model theory is wrong and the GPU work should not be
        # started on this reasoning.
        #
        # Do NOT deploy this together with the objects.track expansion --
        # tracking more classes creates more tracked objects, hence more
        # regions per frame, which moves detection_fps in the OPPOSITE
        # direction and would make this measurement unreadable.
        #
        # This is a diagnostic, not the fix. Lowering a confidence threshold to
        # quiet a weak model trades false negatives for stability, so it should
        # not outlive the experiment.
        filters.car.threshold = 0.6;
      };

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
    # /var/lib/frigate on the root filesystem, and the fleet's ~539 GB/day would
    # fill the 465 GB root disk in under a day -- then mounting the media disk
    # later would hide that footage without deleting it.
    #
    # With this, the host always boots and stays monitored while the recorder
    # declines to run in a state where it would do damage.
    unitConfig.RequiresMountsFor = "/var/lib/frigate";

    serviceConfig = {
      # ── Credentials ───────────────────────────────────────────────────────
      #
      # The camera username/password are shared across every camera and
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

      # Drop stale per-camera shared-memory segments before starting.
      #
      # Frigate creates every one of its /dev/shm segments under
      # `except FileExistsError: pass` (util/image.py:842-850) and never
      # resizes or removes one. /dev/shm also survives a service restart:
      # PrivateTmp= does not cover it, and Frigate uses "untracked" shared
      # memory deliberately so segments outlive a crash.
      #
      # So any segment whose SIZE is derived from config outlives the config
      # change that sized it, and the next start silently attaches to the old
      # one. There are two independent families, both affected:
      #
      #   /dev/shm/<camera>          detector input, sized
      #                              model.width * model.height * 3
      #   /dev/shm/out-<camera>      detection output, fixed 20 * 6 * 4
      #   /dev/shm/<camera>_frameN   frame ring buffers, sized
      #                              detect.height * 3/2 * detect.width
      #                              (camera/maintainer.py:156-157)
      #
      # The failure is the same either way: a camera process dies with
      #
      #   TypeError: buffer is too small for requested array
      #
      # while the service still reports active and keeps recording. Observed
      # here on the MODEL family switching 320x320 -> 416x416: every one of the
      # segments stayed 307200 bytes from the previous generation and every
      # camera process crashed on startup. It cost a live debugging session.
      #
      # The frameN family used to be left alone here, on the reasoning that it
      # is sized from the camera's own detect resolution rather than the
      # model's and so is not disturbed by model changes. That is true and also
      # beside the point -- it just moves the trigger from "change the detector
      # model" to "change any camera's detect width/height", which is an
      # equally ordinary edit to this file. Leaving it out made the detect
      # geometry in the inventory above quietly load-bearing: correct only for
      # as long as nobody touched it. Both families are cleared now, so detect
      # resolution is a freely editable number again.
      #
      # Still not a blunt "wipe /dev/shm": every path is derived from a known
      # camera name, so this cannot touch Frigate's other IPC. In particular
      # the `birdseye` segment (output/birdseye.py:801, created only when
      # birdseye.restream is on) is not per-camera and is not matched -- and
      # `<cam>_frame*` cannot cross-match a camera whose name is a prefix of
      # another, since the `_frame` infix has to match too.
      #
      # This APPENDS to the three ExecStartPre entries the upstream module
      # already defines (clear-cache, create-writable-config,
      # libavformat-major-version) -- verified by evaluating the merged list,
      # since replacing them would break config generation entirely.
      #
      # Safe to run unconditionally: the segments are pure IPC scratch space,
      # recreated on start, and the service is stopped when this executes.
      #
      # The trailing glob is unquoted on purpose, and it relies on BASH's
      # unmatched-glob behaviour: with no match, bash passes the literal
      # `<cam>_frame*` through and `rm -f` ignores it, so this exits 0 on a
      # fresh boot where no segment exists yet. That matters because a failing
      # ExecStartPre aborts the unit start entirely. pkgs.writeShellScript uses
      # runtimeShell, which is bash here -- do NOT port this loop to a shell
      # with zsh's nullglob-off semantics, where an unmatched glob is a fatal
      # error that would abort the command BEFORE the two quoted rm targets are
      # processed, silently reintroducing the stale-segment bug it fixes.
      ExecStartPre = [
        (pkgs.writeShellScript "frigate-clear-stale-shm" ''
          for cam in ${lib.escapeShellArgs (builtins.attrNames cameras)}; do
            rm -f "/dev/shm/$cam" "/dev/shm/out-$cam" "/dev/shm/$cam"_frame*
          done
        '')
      ];
    };
  };

  # restartUnits is set directly (rather than reusing mkContainerSecret from
  # modules/services/mk-container-secret.nix) because that helper hardcodes
  # `restartUnits = [ "docker-${containerName}.service" ]`, and nvrhub runs no
  # Docker containers -- Frigate is the native `services.frigate` module,
  # started as `systemd.services.frigate` (see LoadCredential= above). Pointing
  # restartUnits at a nonexistent docker-frigate.service would restart nothing
  # while looking fixed. Without restartUnits here at all, rotating the shared
  # camera credential and redeploying would leave Frigate's LoadCredential=
  # holding the stale password with no error and no restart -- the same
  # silent-stale-credential failure mode documented for the attic token at
  # modules/services/attic/attic_server.nix:36-40.
  sops.secrets = {
    "cameras/username" = {
      restartUnits = [ "frigate.service" ];
    };
    "cameras/password" = {
      restartUnits = [ "frigate.service" ];
    };
  };

  # Expose Frigate's Prometheus metrics to the monitoring master.
  #
  # Frigate serves a native /api/metrics endpoint (frigate_camera_fps,
  # frigate_detection_fps, frigate_detector_inference_speed_seconds,
  # frigate_storage_*, ...), which the alert rules in
  # ../../../modules/monitoring/master/alert-rules/frigate-alerts.yaml consume.
  #
  # WHY THIS NEEDS A DEDICATED VHOST
  #
  # /api/metrics requires authentication INSIDE Frigate, not merely in nginx.
  # In frigate/api/app.py the route is declared
  #
  #     @router.get("/metrics", dependencies=[Depends(allow_any_authenticated())])
  #
  # and allow_any_authenticated() raises 401 unless a `remote-user` request
  # header is present, with no config option to exempt it. Three earlier attempts
  # failed, and each failure is worth recording so it is not repeated:
  #
  #   1. A location that BYPASSED nginx's auth_request. Cannot work: skipping the
  #      subrequest guarantees `remote-user` is absent, so Frigate 401s.
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
  #      remote-user: anonymous; 80 -> 401) but the override could not be made to
  #      stick, because the upstream module already sets `proxy_set_header
  #      X-Server-Port $server_port` in that same location and nginx honours the
  #      FIRST of duplicate proxy_set_header directives.
  #   3. A bare socat TCP relay from the LAN to 127.0.0.1:5000. It worked for
  #      metrics, and that was the problem: Frigate's escape hatch is scoped to
  #      the PORT, not to a path, so republishing that port republished the whole
  #      authenticated API. Verified from sdrhub while it was deployed --
  #      /api/config, /api/events, /api/version and /api/<camera>/latest.jpg all
  #      returned 200 to an unauthenticated LAN client. Camera credentials were
  #      redacted by Frigate (rtsp://*:*@...), so nothing secret leaked, but live
  #      snapshots and the event/recording API were readable by any LAN host.
  #      Caught in review on PR #2191.
  #
  # The upstream module gives this vhost a `listen 127.0.0.1:5000` (added for
  # nixpkgs#370349, "Frigate wants to connect on 127.0.0.1:5000 for
  # unauthenticated requests"), and on that listener $server_port genuinely IS
  # 5000, so the module's own unmodified /auth location takes the anonymous
  # branch. Verified: `curl 127.0.0.1:5000/api/metrics` -> 200 with 231 frigate_*
  # series, while the same path on :80 -> 401.
  #
  # So the fix is a separate nginx server on :9634 that proxies EXACTLY ONE PATH
  # to that listener. The upstream connection still arrives on :5000, so the
  # anonymous branch still applies, but nothing other than /api/metrics is
  # routable -- there is no location for anything else, so every other path gets
  # 404 from this vhost rather than being forwarded. That is what makes the
  # port-scoped bypass safe to expose.
  services.nginx.virtualHosts."frigate-metrics" = {
    listen = [
      {
        addr = "0.0.0.0";
        port = 9634;
      }
      # Prometheus targets the hostname nvrhub.local, and mDNS / the AdGuard
      # rewrite may answer with an AAAA record, so the scrape can arrive over
      # IPv6. An IPv4-only listener would fail those scrapes intermittently
      # rather than obviously. Raised in review on PR #2191.
      {
        addr = "[::]";
        port = 9634;
      }
    ];

    # Only this one path exists on this server. No `/`, no prefix match, no
    # fallthrough: an exact-match location and nothing else, so the whole rest
    # of Frigate's API is unroutable here by construction rather than by an
    # allow/deny list that could be edited wrong later.
    locations."= /api/metrics" = {
      # Proxying to the module's 127.0.0.1:5000 listener rather than to Frigate
      # (127.0.0.1:5001) is load-bearing: it is that hop which makes
      # $server_port 5000 inside the /auth subrequest, which is what yields
      # remote-user: anonymous. Pointing this at :5001 directly would 401.
      proxyPass = "http://127.0.0.1:5000/api/metrics";
      recommendedProxySettings = true;
      extraConfig = ''
        allow 192.168.31.0/24;
        allow 127.0.0.1/32;
        deny all;

        access_log off;
      '';
    };
  };

  networking.firewall.allowedTCPPorts = [
    80 # nginx -> Frigate UI
    9634 # nginx frigate-metrics vhost (/api/metrics only) -> Prometheus
  ];
}
