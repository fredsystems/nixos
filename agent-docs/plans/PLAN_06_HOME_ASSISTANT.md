# Plan 06: Home Assistant on corehub

- **Status:** planned
- **Branches:** none yet. Proposed: one `plan06/6.N-*` branch and PR per
  subtask, as Plan 04 did.

## Goal

Run Home Assistant on corehub as the house's automation hub, starting
from what already exists:

- The Z-Wave network on the old Aeotec stick, adopted as-is, so the
  light switches, dimmers and the fan controller come back without
  re-pairing.
- Frigate on nvrhub, connected so camera state is visible to and
  controllable from Home Assistant.

Then build the first real automation on top: indoor cameras that stop
raising alerts while the owner is home and awake, and raise them again
when he is asleep or away, driven by what he actually did rather than
by a schedule.

Garage door control (Plan 07) and Apple Home / Siri (Plan 08) follow
once this plan's core works: switches and dimmers controllable, and the
cameras arming as designed.

## Background

### Why not a schedule

The owner works air traffic control on a rotating schedule. Weekdays
0630-1500 today; in a few months Wednesday to Sunday with shifts at
1500-2300, 1330-2130, 0800-1600, 0530-1330 and a midnight-0800 that is
followed by sleep from about 0845 to noon. No day/time rule survives
that, and he travels. Sleep and wake are therefore explicit actions
(NFC tags, see "House mode"), and presence is the iOS app's geofence.

### Z-Wave stick inventory (2026-11-26)

Read with zwave-js 15.32.3 on daytona, before any Home Assistant
existed. The raw NVM backup was taken first:
`/tmp/opencode/zwave/nvm-d4558e0a-1795727321766.bin` (256 KiB; must be
moved somewhere durable, see 6.1).

- Aeotec Z-Stick Gen5, ZW090-A (US, 908.42 MHz), firmware 1.1, Z-Wave
  protocol 4.54. Primary controller, node 1, home ID `d4558e0a`. No SUC.
- 75 nodes besides the controller: 19 mains-powered and alive, 30
  mains-powered and dead, 24 battery (asleep or unknown), 2 FLiRS
  locks (dead).

The 19 live nodes, all fully interviewed:

| Node(s)                    | Device                           | Kind            |
| -------------------------- | -------------------------------- | --------------- |
| 16, 32, 33                 | GE/Enbrighten 26933 motion       | dimmer          |
| 19, 23, 42, 53             | GE 14294 paddle                  | dimmer          |
| 17, 34                     | GE/Enbrighten 26931 motion       | on/off switch   |
| 13, 38, 41, 48, 49, 50, 97 | Inovelli NZW30                   | on/off switch   |
| 43                         | GE 14287 in-wall fan speed       | fan controller  |
| 7, 44                      | Neo NAS-WR01Z                    | plug-in switch  |

All 19 answered an unencrypted Get of their switch state, so none was
included with S0 or S2 and none needs the old network keys, which are
gone with the old Home Assistant config. The Inovellis _support_ S2
(zwave-js warns about the missing keys) but were included without it.

The dead nodes include fan controllers 9, 18 and 24 and fourteen "Secure
Barrier Add-on" nodes (65-95), which look like one garage controller
included over and over. Dead was measured from daytona, not from the
stick's final position, so routing may revive some; see 6.9.

## Decisions

### corehub, native NixOS modules

corehub is the LAN's infrastructure host, has the capacity (13 GB of
15 GB free, 103 GB disk free, 16 cores, measured 2026-11-26) and
already terminates `*.int.fredsystems.org`. nvrhub was rejected: its
disk is a 7.9-year-old surveillance drive, and house lighting should
not share a failure domain with the NVR.

Everything uses nixpkgs modules: `services.home-assistant`,
`services.mosquitto`, `services.zwave-js`. No containers, no HACS. The
Frigate integration comes from nixpkgs as
`home-assistant-custom-components.frigate`.

### The Z-Wave network is adopted, not rebuilt

zwave-js joins the network already in the stick's NVM, so every live
node keeps its node ID and inclusion. Fresh S0 and S2 keys are
generated into sops for future secure inclusions; no existing device
uses keys, so this changes nothing on the network.

`services.zwave-js` (the headless server) rather than `zwave-js-ui`:
its keys come from `secretsConfigFile`, so they live in sops like every
other secret. zwave-js-ui keeps keys and settings in a UI-managed
`settings.json` under its store directory, which is not declarative.
Home Assistant's own Z-Wave panel covers what the UI would be used for:
naming, re-interviewing, the network graph and removing failed nodes.

The Gen5 (not Gen5+) has a known enumeration problem on some USB 3
controllers. If it misbehaves on corehub, a USB 2 port or a short USB 2
extension cable is the fix; the cable also gets the radio away from the
case.

### Mosquitto on corehub, one user per client

Frigate's Home Assistant integration needs MQTT for its switches and
sensors, and MQTT is currently disabled in Frigate. Mosquitto runs on
corehub with password authentication and one user per client
(`homeassistant`, `frigate`, `nvr-watchdog`), each password a sops
secret. Frigate reads its password through the same `LoadCredential=`
mechanism as its camera credentials (`hosts/linux/nvrhub/frigate.nix`).

### Home Assistant reaches Frigate on its TLS name

The integration talks to `https://nvr.int.fredsystems.org` with a
dedicated Frigate login. Frigate's unauthenticated `127.0.0.1:5000`
listener stays loopback-only; republishing it would expose the whole
API, which is exactly what PR #2191's review caught for the metrics
port.

### The UI owns devices; Nix owns the house mode

Home Assistant integrations are config entries created in the UI and
stored under `.storage` in the module's `configDir`, as are device and
entity names.
That cannot be declared and is not fought.

The house-mode state machine and everything that arms or disarms
cameras is declared in Nix, so it is reviewed and versioned. Casual
automations (lights, scenes) stay in the UI through an
`automations.yaml` include, so experimenting with them never needs a
deploy.

### Home Assistant is published like Grafana

Bound to loopback, reached only through a corehub nginx vhost at
`ha.int.fredsystems.org`, with websocket upgrade headers,
`use_x_forwarded_for` and `trusted_proxies = [ "127.0.0.1" ]`. No
plaintext legacy name.

## House mode

The design the owner and the agent settled on, 2026-11-26.

### States

| Mode         | Indoor camera alerts | Meaning                       |
| ------------ | -------------------- | ----------------------------- |
| `away`       | on                   | owner's phone is not home     |
| `home_awake` | off                  | home, and said he is up       |
| `home_sleep` | on                   | home, and said he is sleeping |

Held in an `input_select` so it survives Home Assistant restarts.

### Transitions

| From         | To           | Trigger                                    |
| ------------ | ------------ | ------------------------------------------ |
| any          | `away`       | phone leaves the home zone                 |
| `away`       | `home_awake` | phone enters the home zone                 |
| `home_awake` | `home_sleep` | "goodnight" NFC tag scanned, while home    |
| `home_sleep` | `home_awake` | "morning" NFC tag scanned, while home      |
| `home_awake` | `home_sleep` | 18 h with no renewal (expiry, see below)   |

The goodnight tag is beside the bedside MagSafe dock, not under it: an
iPhone reads tags in the background whenever it is unlocked, so a tag
under the docked phone would fire whenever he glances at it. The
morning tag is somewhere he goes every morning. Two tags rather than
one toggle, because a toggle is one accidental double tap away from
disarming the house while he is in bed.

### Rules the design depends on

- **Arming may be triggered by weak signals; disarming only by
  deliberate ones.** A wrong arm costs some spurious alerts. A wrong
  disarm turns the cameras off when they matter.
- **Camera and motion evidence may only ever arm.** "Frigate sees
  someone in the kitchen" looks like "he is awake", and it is equally
  what an intruder at 3 am looks like. If motion could disarm, the
  system would disarm for exactly the person it exists to record.
- **Alarms trigger nothing.** On days off the iOS sleep schedule is
  not an alarm, and an alarm in a hotel room must not touch the house.
  Every transition except leaving is gated on the phone being home.
- **`home_awake` expires.** Arriving home, a tag scan or a manual
  selection renews it. After 18 h without renewal it falls to
  `home_sleep` and sends a notification offering to disarm. A dead
  phone or a missed geofence cannot leave the house disarmed for days.

### What arming changes

For the indoor cameras: `review_alerts` and `review_detections` on in
`away` and `home_sleep`, off in `home_awake`. Object detection stays on
in every mode, so detection still feeds Home Assistant (which the
arm-only evidence rule needs), and continuous recording keeps all
footage for its 10 days regardless. Only review items, and the 30-day
alert retention that comes with them, are skipped while he is home and
awake.

### Failing safe

- **Frigate restarts armed.** Runtime switch changes are not persisted;
  Frigate comes back with the Nix config, where review is enabled. Home
  Assistant re-applies the current mode when Frigate's MQTT
  availability topic goes `online`.
- **Home Assistant down means re-armed, not stuck.** If Home Assistant
  dies in `home_awake`, nothing would ever re-arm. A small watchdog on
  nvrhub (6.17) watches a heartbeat Home Assistant publishes and, if it
  goes stale, re-enables review on the indoor cameras through Frigate's
  local websocket, with no dependency on the broker or on corehub.

## Execution model

Strictly sequential: each phase builds on the one before.

- Phase 1 is deployable on its own: Home Assistant, Mosquitto and
  zwave-js running on corehub with nothing depending on them.
- Phase 2 needs the owner at the house to identify each switch (6.8).
- Phase 4 needs his phone: the companion app, the geofence and the tags.

Plan 02 is in progress. This plan touches nothing Plan 02 records or
depends on, but under `plan-sequencing-discipline` it cannot complete
ahead of Plan 02 without the owner deciding so, as he did for Plans 03
to 05. Decide at activation.

Phase 1 is decomposed here against the code as of 2026-11-26. Phases 2
to 4 carry their scope and decisions only, and are decomposed when
each phase activates.

## Open questions

Decide at activation:

1. **Remote access for the phone.** The geofence's leave and arrive
   updates and the companion app need to reach Home Assistant from off
   the LAN. Tailscale on the phone (corehub is already the subnet
   router) or Nabu Casa. Is the phone on the tailnet?
2. **Household.** Is the owner the only occupant? With more people,
   `away` means everyone gone and the sleep tags need an owner each.
3. **Pets while armed.** The dog is tracked indoors. Armed overnight
   with pets on may be a night of dog alerts. Pets off when armed and
   only people re-armed, or pets on?
4. **Which cameras are indoor.** kitchen, living_room, office and
   upstairs_hall for certain. inside_garage too?
5. **Notifications.** Does armed also mean a push notification for a
   person indoors while `away` or `home_sleep`, or review items only?
6. **Backing up Home Assistant's state.** Device names, integrations
   and the recorder live in the module's `configDir`. Is the NAS's nightly pull
   extended to cover it (with a consistent SQLite dump, as
   `modules/services/sqlite-backup.nix` does for acarshub), or is
   Home Assistant's own backup used?
7. **Where the NVM backup lives.** Encrypted into the repo with sops
   (binary mode), or kept off-repo.
8. **Expiry length.** 18 h is proposed; it only re-arms with a
   notification, so erring short is cheap.

## Subtasks

### Phase 1: foundation on corehub

- [ ] **6.1 Stick on corehub.** Move the ZW090 to corehub. Record its
      `/dev/serial/by-id` path and the USB port it is on. Re-run the
      read-only inventory (`/tmp/opencode/zwave/inventory.cjs`) from the
      stick's final position and record the alive/dead counts here,
      since dead nodes were measured from daytona. Store the NVM backup
      per open question 7. Nothing is installed yet.
- [ ] **6.2 Secrets.** New sops entries: zwave-js S0 and S2 keys
      (generated fresh), and Mosquitto passwords for `homeassistant`,
      `frigate` and `nvr-watchdog`. Recipients: corehub, plus nvrhub for
      the `frigate` and `nvr-watchdog` passwords only.
- [ ] **6.3 Mosquitto.** `services.mosquitto` on corehub: one listener on
      1883, LAN-reachable for nvrhub, password auth per user from 6.2,
      no anonymous access. Firewall opening for 1883 only.
- [ ] **6.4 zwave-js.** `services.zwave-js` on corehub against the
      by-id path from 6.1, keys from 6.2 via `secretsConfigFile`, server
      on loopback only (Home Assistant is the only client). Verify: the
      server starts and reports home ID `d4558e0a` and the 19 live nodes.
- [ ] **6.5 Home Assistant.** `services.home-assistant` on corehub, with
      `extraComponents` for `zwave_js`, `mqtt`, `mobile_app` and the
      defaults; the Frigate custom component; loopback bind; the
      `ha.int.fredsystems.org` vhost and AdGuard rewrite through
      corehub's `migratedVhosts`; an `automations.yaml` include for
      UI-made automations. Verify: onboarding page loads over TLS.
- [ ] **6.6 Monitoring.** A blackbox probe for `ha.int.fredsystems.org`,
      and alert rules with tests for Home Assistant, zwave-js and
      Mosquitto being down, in the style of
      `modules/monitoring/master/alert-rules/frigate-alerts.yaml`.

### Phase 2: devices

- [ ] **6.7 Adopt the network.** Add the Z-Wave JS integration in Home
      Assistant against the 6.4 server. Expect the 19 live nodes from the
      inventory with model and manufacturer, unnamed.
- [ ] **6.8 Identify every switch.** With the owner at the house:
      Home Assistant's logbook shows which node reports when a switch is
      flipped, so he flips each switch in turn and the node is named for
      its room and load. The plug-in switches (7, 44) are identified by
      toggling them from Home Assistant instead. The result is recorded
      here as a node, room and load table.
- [ ] **6.9 Dead and ghost nodes.** Deferred by the owner (2026-11-26).
      Remove the "Secure Barrier Add-on" ghosts and other confirmed-dead
      nodes with "remove failed node"; find out whether fan controllers
      9, 18 and 24 still physically exist. The garage controller itself
      is re-included securely in Plan 07, not here.

### Phase 3: Frigate

- [ ] **6.10 Frigate MQTT.** Enable MQTT in `hosts/linux/nvrhub/frigate.nix`
      against corehub's broker, password via `LoadCredential=`.
- [ ] **6.11 Frigate integration.** A dedicated Frigate user for Home
      Assistant (role decided at activation), and the integration
      configured against `https://nvr.int.fredsystems.org`.
- [ ] **6.12 Verify control.** Toggling an indoor camera's review switch
      in Home Assistant flips it in Frigate, and a Frigate restart
      returns it to the Nix default.

### Phase 4: house mode

- [ ] **6.13 Presence.** The iOS companion app, the home zone, and the
      remote-access route from open question 1.
- [ ] **6.14 NFC tags.** Write the goodnight and morning tags from the
      companion app and record their tag IDs.
- [ ] **6.15 Mode state machine.** The `input_select`, transitions and
      expiry from "House mode", declared in Nix.
- [ ] **6.16 Camera effect.** Mode changes drive the indoor cameras'
      review switches, and the current mode is re-applied whenever
      Frigate's availability goes `online`.
- [ ] **6.17 nvrhub watchdog.** Home Assistant publishes a heartbeat. On
      nvrhub, a service re-enables review on the indoor cameras through
      Frigate's local websocket when the heartbeat is stale.
- [ ] **6.18 End-to-end test.** Every row of the transitions table, plus
      Home Assistant stopped while `home_awake`, Frigate restarted in
      each mode, the expiry, and a tag scanned while away (must do
      nothing).
