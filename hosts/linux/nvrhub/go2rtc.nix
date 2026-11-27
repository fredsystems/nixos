# go2rtc RTSP restream of each camera, for Home Assistant's live view and
# Apple Home (Plan 06; Plan 08, 8.6).
#
# The streams are Frigate's `go2rtc.streams` setting in ./frigate.nix, which
# also tells Frigate (and through it Home Assistant's Frigate integration)
# that they exist, so the list is declared once: each camera's main stream
# under its own name, and its substream as `<cam>_sub`, which is what Home
# Assistant and Apple Home play. go2rtc opens a camera only while someone is watching, and Frigate
# keeps reading the cameras directly, so recording and detection are
# untouched.
#
# RTSP on :8554 is LAN-reachable and needs a login, except from loopback,
# which go2rtc lets through (internal/rtsp/rtsp.go). The API stays on
# loopback, where the Frigate module's nginx proxies it for Frigate's UI.
# WebRTC cannot be switched off, so it is bound to loopback too.
#
# go2rtc substitutes `${NAME}` in its config from $CREDENTIALS_DIRECTORY/NAME
# (pkg/creds/creds.go), so the camera credentials and its own RTSP password
# come from sops through LoadCredential=, never the store.
{ config, lib, ... }:
let
  port = 8554;

  restreams = config.services.frigate.settings.go2rtc.streams;
in
{
  services.go2rtc = {
    enable = true;
    settings = {
      api.listen = "127.0.0.1:1984";
      rtsp = {
        listen = ":${toString port}";
        username = "homeassistant";
        password = "\${RTSP_PASSWORD}";
      };
      webrtc.listen = "127.0.0.1:8555";
      streams = lib.mapAttrs (_: lib.head) restreams;
    };
  };

  systemd.services.go2rtc.serviceConfig.LoadCredential = [
    "CAMERA_USER:${config.sops.secrets."cameras/username".path}"
    "CAMERA_PASSWORD:${config.sops.secrets."cameras/password".path}"
    "RTSP_PASSWORD:${config.sops.secrets."home-assistant/go2rtc_rtsp_password".path}"
  ];

  # The camera credentials are declared in ./frigate.nix, with Frigate's
  # restart; rotating them should restart go2rtc too.
  sops.secrets = {
    "cameras/username".restartUnits = [ "go2rtc.service" ];
    "cameras/password".restartUnits = [ "go2rtc.service" ];
    "home-assistant/go2rtc_rtsp_password".restartUnits = [ "go2rtc.service" ];
  };

  # Login required from off-host; Home Assistant on corehub is the client.
  networking.firewall.allowedTCPPorts = [ port ];
}
