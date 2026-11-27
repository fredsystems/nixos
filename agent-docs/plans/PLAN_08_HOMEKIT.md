# Plan 08: Apple Home and iOS integration

- **Status:** in progress, started on 2026-11-26 by the owner's
  decision while Plans 06 and 07 are on hold; see "Execution model".
- **Depends on:** Plan 06 (Home Assistant and its devices) and Plan 07
  (the garage door entity, if it is to be exposed).
- **Branch:** `plan06/home-assistant`, shared with Plan 06 and one PR.

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
  Homebridge plugin and no Home Assistant integration. There is no
  existing Homebridge to migrate (owner, 2026-11-26).
- **An explicit allowlist of entities.** Lights, dimmers and the fan
  from Plan 06, and the garage door from Plan 07. Nothing is exposed by
  default, so adding a device to Home Assistant never silently adds it
  to Apple Home.
- **Every Plan 06 device except the garbage disposal** (owner,
  2026-11-26), so "Hey Siri, turn everything on" cannot start it.
- **On/off switches whose load is a light are exposed as lights.**
  HomeKit treats a `switch` as a switch, so Siri's "lights" commands and
  the Home app's light controls would skip the stair, hallway, porch,
  laundry, kitchen and vanity lights and the two lamps. Each is wrapped
  in a template light of the same name, with its own `unique_id`, in
  `configuration.yaml`, and the wrapper is exposed. The reconciler gives
  the wrapper its switch's area and hides the switch, so each load shows
  once. The `switch` light platform was tried first and dropped: it
  takes its registry ID from the switch at startup, so on a fresh
  install it is never registered and cannot have an area.
- **Declared in `configuration.yaml`.** The bridge is a `homekit:`
  entry, which Home Assistant imports into its config entry on every
  start. Pairing with the Home app is the one manual step.
- **LAN only.** The bridge binds to and advertises corehub's LAN
  address. Remote control goes through the HomePod as home hub, not
  through any port opened beyond the LAN.
- **Apple's own garage door protection applies.** iOS requires the
  device to be unlocked before a garage door accessory can be operated
  from the lock screen, Control Center or Siri. This plan relies on
  that rather than adding its own confirmation, and does not weaken
  Plan 07's "nothing opens the door automatically".

## Open questions

Answered 2026-11-26:

1. **Home hub.** A HomePod is in the house, so Apple Home works away
   from home and HomeKit automations run.
2. **Networking on corehub.** avahi already runs there with UDP 5353
   open. The bridge needs only its own TCP port, 21063.
3. **House mode in Apple Home.** Deferred until Plan 06 builds house
   mode (6.15); see 8.5.
4. **Cameras.** Deferred until Plan 06 integrates Frigate (6.11); see
   8.6.
5. **Existing Homebridge.** None.

## Execution model

Plans 06 and 07 are on hold and Plan 08 started anyway, by the owner's
decision. It needs only Plan 06's devices, which exist. All three share
one branch and one PR, so under `plan-sequencing-discipline` the PR
merges when all three are complete, unless the owner decides otherwise
then.

## Subtasks

- [ ] **8.1 Bridge.** `hosts/linux/corehub/home-automation/homekit.nix`:
      the `homekit` component and a `homekit:` entry on port 21063,
      bound to and advertised on 192.168.31.20, its allowlist built from
      Plan 06's device table minus the disposal. The template light
      wrappers in `devices.nix`, with their areas, and floors (Upstairs,
      Downstairs) for every area. Firewall opening for 21063/tcp. Verify: the bridge
      advertises `_hap._tcp` on the LAN and Home Assistant shows the
      pairing notification.
- [ ] **8.2 Pair.** The owner adds the bridge in the Home app with the
      code from the notification. Home Assistant areas do not carry over
      to Apple Home rooms, so the owner assigns rooms there, once.
- [ ] **8.3 Verify.** Each exposed accessory responds from the Home
      app, Siri ("turn off the kitchen lights") and away from home
      through the HomePod.
- [ ] **8.4 Garage door.** Once Plan 07 provides the entity.
- [ ] **8.5 Goodnight.** A Siri-triggered "Goodnight" scene as a
      deliberate trigger for `home_sleep`, once Plan 06 builds house
      mode.
- [ ] **8.6 Cameras.** Whether to expose Frigate's cameras as live
      streams, once Plan 06 integrates Frigate.
