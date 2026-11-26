# zwave-js server for the Aeotec Z-Stick Gen5 moved here in Plan 06, 6.1.
# Plan 06, 6.4.
#
# It joins the network already in the stick's NVM (home ID d4558e0a), so
# every node keeps its ID and inclusion. The S0 and S2 keys in sops were
# generated fresh in 6.2: no existing node was included securely, so they only
# matter for future secure inclusions.
#
# Loopback only, with service discovery off: Home Assistant on this host is
# the only client, and the port is not in the firewall either.
{ config, ... }:
{
  services.zwave-js = {
    enable = true;
    serialPort = "/dev/serial/by-id/usb-0658_0200-if00";
    secretsConfigFile = config.sops.secrets."home-assistant/zwave_js_keys".path;
    extraFlags = [
      "--host"
      "127.0.0.1"
      "--disable-dns-sd"
    ];

    # No soft reset. On a 500-series stick it makes the USB device
    # re-enumerate, possibly as a different ttyACM node than the one the
    # unit's DeviceAllow= admitted at start. 6.1's inventory ran this way.
    settings.features.softReset = false;
  };

  sops.secrets."home-assistant/zwave_js_keys".restartUnits = [ "zwave-js.service" ];
}
