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
  inherit (config.services.home-assistant) unstablePkgs;

  # FIXME(nixpkgs-zwave-js-server-3.12): WORKAROUND, not a fix. Home
  # Assistant 2026.11 (./unstable.nix) needs zwave-js-server's API schema 52,
  # which arrived in zwave-js-server 3.12.0 (2026-11-10); nixpkgs unstable
  # still has 3.11.0 (schema 51), so the Z-Wave JS entry stays in setup_retry
  # and no Z-Wave device works. This is unstable's own recipe at 3.12.0.
  # Delete it, and use `unstablePkgs.zwave-js-server` directly, once nixpkgs
  # unstable has 3.12.0 or later. Tracked in .github/tracked-upstream-fixes.json,
  # checked by .github/workflows/track-upstream-fixes.yaml.
  zwaveJsServer = unstablePkgs.zwave-js-server.overrideAttrs (_: rec {
    version = "3.12.0";
    src = unstablePkgs.fetchFromGitHub {
      owner = "zwave-js";
      repo = "zwave-js-server";
      rev = version;
      hash = "sha256-jhHeQfWtDPEnSdA9/s6p04f++3JHMeC/AWsGNgWpv9o=";
    };
    npmDeps = unstablePkgs.fetchNpmDeps {
      inherit src;
      name = "zwave-js-server-${version}-npm-deps";
      hash = "sha256-BirJSLT6HbdD78RmS1Vyq+g4j0x4K8nKEdWeGDz+L3k=";
    };
  });

  # zwave-js's own device files, as shipped inside zwave-js-server.
  deviceConfigs = "${cfg.package}/lib/node_modules/@zwave-js/server/node_modules/@zwave-js/config/config/devices";

  # FIXME(zwave-js-configurationcc-unexpected-report-crash): WORKAROUND, not a
  # fix. zwave-js crashes the whole server when a node answers a Configuration
  # Get with a report for a different parameter that it cannot parse:
  # ConfigurationCCAPI.get() logs `response.value.toString()` unguarded
  # (ConfigurationCC.ts, still so on master on 2026-11-26). The front door's
  # Kwikset 910 (Plan 06) does that: its secure replies come late enough to
  # be matched against a later query. Dropping only its user-code parameters
  # (1-30) was not enough; any of them can trip it. So every interview
  # attempt took zwave-js, and with it every Z-Wave device in Home Assistant,
  # down.
  #
  # The override is that same file with no configuration parameters, so the
  # interview has none to read. Lost: the DIP-switch settings (keypad LED,
  # auto-lock, buzzer) as entities; they still apply on the lock. User codes
  # stay on the lock and are read through User Code CC. Delete this override,
  # and the deviceConfigPriorityDir setting, once the zwave-js in
  # zwave-js-server guards that log line. Tracked in
  # .github/tracked-upstream-fixes.json, checked by
  # .github/workflows/track-upstream-fixes.yaml.
  deviceConfigOverrides =
    pkgs.runCommand "zwave-js-device-config-overrides"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        mkdir -p "$out/0x0090/templates"
        cp ${deviceConfigs}/0x0090/templates/kwikset_template.json "$out/0x0090/templates/"
        jq '.paramInformation = []' ${deviceConfigs}/0x0090/910.json > "$out/0x0090/910.json"
      '';
in
{
  services.zwave-js = {
    enable = true;
    # Matching Home Assistant, which comes from unstable (./unstable.nix).
    package = zwaveJsServer;
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
