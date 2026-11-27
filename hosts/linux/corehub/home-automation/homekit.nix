# Home Assistant's HomeKit Bridge, for the Home app, Siri, Control Center
# and the Watch. agent-docs/plans/PLAN_08_HOMEKIT.md.
#
# Declared in configuration.yaml, which Home Assistant imports into its
# config entry on every start, so the reconciler keeps it. Pairing with the
# Home app is the one manual step: Home Assistant shows the code as a
# notification until the bridge is paired.
#
# An explicit allowlist, built from ./devices.nix, so a device added to Home
# Assistant is never silently added to Apple Home.
{ config, lib, ... }:
let
  # "Hey Siri, turn everything on" must not start it.
  notExposed = [ "switch.garbage_disposal" ];

  # Switches that ./devices.nix also wraps as lights are exposed as the light,
  # so Siri's "lights" commands and the Home app's light controls include
  # them. The wrapper is light.<same name>.
  wrapped = map (l: l.entity_id) config.services.home-assistant.config.light;
  expose = id: if lib.elem id wrapped then "light.${lib.removePrefix "switch." id}" else id;

  exposed = map expose (
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
