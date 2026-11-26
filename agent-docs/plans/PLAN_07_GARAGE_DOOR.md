# Plan 07: Garage door control

- **Status:** stub
- **Depends on:** Plan 06 (Home Assistant, the adopted Z-Wave network
  and its fresh security keys). Not started until Plan 06's core works:
  switches and dimmers controllable, and the cameras arming as designed.

## Goal

Open, close and see the state of the garage door from Home Assistant,
safely enough that a remote close is something to trust rather than
avoid.

## Background

The 2026-11-26 inventory of the Z-Wave stick (Plan 06, "Z-Wave stick
inventory") lists fourteen nodes reporting the device class "Secure
Barrier Add-on", which is what Z-Wave garage door controllers report:
65, 67, 68, 70, 75, 78, 85-91 and 95. All fourteen are dead. Fourteen
of them almost certainly means one controller included over and over,
which is common with secure inclusions that fail partway. Plan 06's
6.9 removes them.

Z-Wave's Barrier Operator command class must be used over S0 or S2.
The old network keys are gone, so whatever controller is used has to
be included fresh with the keys Plan 06 generates (6.2). That is a new
inclusion, unlike the switches, which were adopted.

`frigate.nix` has a `garage_door` camera, a DS-2CD2342WD-I at
192.168.31.35, temporarily removed on 2026-08-18. If restored, it shows
the door.

## Decisions

- **Nothing opens the door automatically.** No presence, schedule or
  camera trigger may open it. Opening is always an explicit action by
  the owner.
- **Closing remotely needs real door state.** A close command is only
  trusted with a sensor that reports the door's actual position (the
  controller's tilt sensor, or a separate contact sensor), not the
  controller's assumed state, and with the opener's warning beep and
  flash before it moves.
- **The camera confirms; it never commands.** Same arm-only reasoning
  as Plan 06's house mode: camera evidence may raise a notification or
  block an action, never trigger a door movement.

## Open questions

Decide at activation:

1. **Hardware.** Is the old Z-Wave controller still installed, and what
   model is it? If it is gone or unreliable, the alternatives are a
   new Z-Wave or Zigbee controller, or a local-only one such as ratgdo
   (ESPHome, wired to the opener's terminals). What is the opener?
2. **Auto-close.** Close after it has been open for N minutes while
   `away` or `home_sleep`, with a notification first, or notify only?
3. **The garage_door camera.** Restore it as part of this plan?
4. **Exposure.** Whether the door goes to Apple Home is Plan 08's
   question; this plan only provides the entity.
