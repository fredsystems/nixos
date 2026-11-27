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
{
  config,
  pkgs,
  ...
}:
let
  cfg = config.services.zwave-js;

  # zwave-js's own device files, as shipped inside zwave-js-server.
  deviceConfigs = "${cfg.package}/lib/node_modules/@zwave-js/server/node_modules/@zwave-js/config/config/devices";

  # FIXME(zwave-js-configurationcc-unexpected-report-crash): WORKAROUND, not a
  # fix. zwave-js crashes the whole server when a node answers a Configuration
  # Get with a report it cannot parse: ConfigurationCCAPI.get() logs
  # `response.value.toString()` unguarded (ConfigurationCC.ts, still so on
  # master on 2026-11-26). The front door's Kwikset 910 (Plan 06) does that
  # for one of parameters 1-30, which its device file lists as user-code
  # slots read through Configuration CC, so every interview attempt took
  # zwave-js, and with it every Z-Wave device in Home Assistant, down.
  #
  # The override is that same file without parameters 1-30. The codes are
  # still on the lock and readable through User Code CC; only the slow,
  # crash-prone path is dropped. Delete this override, and the
  # deviceConfigPriorityDir setting, once the zwave-js in zwave-js-server
  # guards that log line. Tracked in .github/tracked-upstream-fixes.json,
  # checked by .github/workflows/track-upstream-fixes.yaml.
  deviceConfigOverrides =
    pkgs.runCommand "zwave-js-device-config-overrides"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        mkdir -p "$out/0x0090/templates"
        cp ${deviceConfigs}/0x0090/templates/kwikset_template.json "$out/0x0090/templates/"
        jq '.paramInformation |= map(select(
              (."#" | test("^[0-9]+$") | not) or ((."#" | tonumber) > 30)
            ))' ${deviceConfigs}/0x0090/910.json > "$out/0x0090/910.json"
        # Fail the build rather than ship an override that drops nothing, if
        # upstream ever renumbers the file.
        test "$(jq '.paramInformation | length' ${deviceConfigs}/0x0090/910.json)" -gt \
          "$(jq '.paramInformation | length' "$out/0x0090/910.json")"
      '';
in
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

    settings = {
      # No soft reset. On a 500-series stick it makes the USB device
      # re-enumerate, possibly as a different ttyACM node than the one the
      # unit's DeviceAllow= admitted at start. 6.1's inventory ran this way.
      features.softReset = false;

      storage.deviceConfigPriorityDir = "${deviceConfigOverrides}";
    };
  };

  sops.secrets."home-assistant/zwave_js_keys".restartUnits = [ "zwave-js.service" ];
}
