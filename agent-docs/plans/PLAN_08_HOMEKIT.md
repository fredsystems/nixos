# Plan 08: Apple Home and iOS integration

- **Status:** stub
- **Depends on:** Plan 06 (Home Assistant and its devices) and Plan 07
  (the garage door entity, if it is to be exposed).

## Goal

Control the house from Apple's own surfaces: the Home app, Siri,
Control Center and the Apple Watch, without opening the Home Assistant
app. Home Assistant stays the system of record; Apple Home is a front
end onto it.

## Background

Plan 06 already uses the Home Assistant iOS companion app, for
presence (the home zone) and the NFC sleep and wake tags. That is
separate from Apple Home: the companion app talks to Home Assistant
directly, whereas Apple Home only sees devices through a HomeKit
bridge.

## Decisions

- **Home Assistant's HomeKit Bridge integration, not Homebridge.** Home
  Assistant already holds every device, so its built-in bridge exposes
  them directly. Homebridge would be a second integration layer
  between the same devices and the same phone, with its own plugins to
  keep up to date. Revisit only if a device turns up that has a
  Homebridge plugin and no Home Assistant integration.
- **An explicit allowlist of entities.** Lights, dimmers and the fan
  from Plan 06, and the garage door from Plan 07. Nothing is exposed by
  default, so adding a device to Home Assistant never silently adds it
  to Apple Home.
- **Apple's own garage door protection applies.** iOS requires the
  device to be unlocked before a garage door accessory can be operated
  from the lock screen, Control Center or Siri. This plan relies on
  that rather than adding its own confirmation, and does not weaken
  Plan 07's "nothing opens the door automatically".

## Open questions

Decide at activation:

1. **Home hub.** Is there an Apple TV or HomePod in the house? Without
   one, Apple Home works only on the LAN and HomeKit automations do not
   run. Remote control would then come from the companion app instead.
2. **Networking on corehub.** HomeKit discovery needs mDNS on the LAN
   and a TCP port for the bridge. Confirm that corehub's firewall and
   mDNS setup can support it without exposing anything beyond the LAN.
3. **House mode in Apple Home.** Expose a "Goodnight" scene (for "Hey
   Siri, goodnight") as an extra deliberate trigger for `home_sleep`,
   alongside the NFC tag? Plan 06's rule holds: deliberate actions only.
4. **Cameras.** Expose the Frigate cameras to Apple Home for live view?
   HomeKit Secure Video is not available through Home Assistant's
   bridge, so this would be live streams only.
5. **Existing Homebridge.** Is there an old Homebridge setup with
   plugins worth keeping? The decision above assumes not.
