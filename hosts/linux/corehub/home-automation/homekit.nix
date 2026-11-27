# Home Assistant's HomeKit Bridge, for the Home app, Siri, Control Center
# and the Watch. agent-docs/plans/PLAN_08_HOMEKIT.md.
#
# Declared in configuration.yaml, which Home Assistant imports into its
# config entry on every start, so the reconciler keeps it. Pairing with the
# Home app is the one manual step: Home Assistant shows the code as a
# notification until the bridge is paired.
#
# An explicit allowlist, built from ./devices.nix, ./automations.nix and
# nvrhub's cameras, so a device added to Home
# Assistant is never silently added to Apple Home.
{
  config,
  inputs,
  lib,
  ...
}:
let
  # "Hey Siri, turn everything on" must not start it.
  notExposed = [ "switch.garbage_disposal" ];

  # Switches that ./devices.nix also wraps as lights are exposed as the light,
  # so Siri's "lights" commands and the Home app's light controls include
  # them.
  # The wrapper is light.<same name>; it switches the switch it wraps.
  wrapped = lib.concatMap (
    t: map (l: (lib.head l.turn_on).target.entity_id) (t.light or [ ])
  ) config.services.home-assistant.config.template;
  expose = id: if lib.elem id wrapped then "light.${lib.removePrefix "switch." id}" else id;

  # ./automations.nix's scripts, as switches: "Hey Siri, turn on Good Night".
  scripts = map (name: "script.${name}") (lib.attrNames config.services.home-assistant.config.script);

  # Frigate's cameras, read from nvrhub's own camera table so the two cannot
  # drift: the Frigate integration names each one camera.<Frigate name>.
  # Plan 08, 8.6. Live video is nvrhub's go2rtc restream, re-encoded here to
  # H.264 at what the viewing device asks for, only while someone watches.
  cameras = map (name: "camera.${name}") (
    lib.attrNames inputs.self.nixosConfigurations.nvrhub.config.services.frigate.settings.cameras
  );

  exposed =
    cameras
    ++ scripts
    ++ map expose (
      lib.subtractLists notExposed (
        lib.concatMap (d: map (e: e.entityId) d.entities) config.services.home-assistant-reconciler.devices
      )
    );

  lanAddress = "192.168.31.20";
  port = 21063;
in
{
  services.home-assistant = {
    extraComponents = [ "homekit" ];

    config.homekit = [
      {
        name = "Home Assistant Bridge";
        inherit port;
        # Bound to and advertised on the LAN address only. Left alone, it
        # would also advertise the tailscale and docker addresses, and a
        # phone or the HomePod could pick one it cannot reach.
        ip_address = lanAddress;
        advertise_ip = lanAddress;
        filter.include_entities = exposed;
      }
    ];
  };

  # The bridge's HAP port. mDNS (UDP 5353) is already open for avahi.
  networking.firewall.allowedTCPPorts = [ port ];
}
