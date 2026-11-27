# Plan 06: Home Assistant on corehub

- **Status:** in progress, to complete ahead of Plan 02 by the owner's
  decision; see "Execution model". Paused by the owner on 2026-11-26
  after 6.8, with Plan 08 worked on meanwhile on the same branch.
- **Branches:** 6.1 `plan06/6.1-stick-on-corehub` (#3017). From 6.2 on,
  one branch, `plan06/home-assistant`, and one PR for the rest of the
  plan, by the owner's decision (2026-11-26).

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
existed. A raw NVM backup was taken first and left in daytona's `/tmp`.
It was superseded by the corehub backup in 6.1.

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
stick's final position. Re-measured from corehub in 6.1, four of them
answer.

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

### Home Assistant's configuration is declarative

The owner's requirement (2026-11-26): all Home Assistant configuration
lives in Nix. Nothing that matters is set only in the UI, and wiping
`configDir` loses history, not configuration.

What `services.home-assistant` declares directly, through
`configuration.yaml`:

- Automations, scripts, scenes and helpers (`input_select`, timers,
  templates). These are YAML-native and go in `config`. No
  `automations.yaml` include: the UI editor shows them read-only.
- Dashboards, through `lovelaceConfig` (YAML mode).
- Display names and icons per entity, through `homeassistant.customize`.

What Home Assistant keeps only in `.storage`, where YAML cannot reach:

- Config entries for integrations that are UI-only: `zwave_js`,
  `mqtt`, `mobile_app` and Frigate.
- The device and entity registries: entity IDs, areas, device names.
  `customize` changes only how a name is shown. The entity ID that
  automations refer to stays whatever Home Assistant generated.
- Onboarding (the owner account).

The owner chose (2026-11-26) to close that gap with a reconciler (6.19):
a oneshot unit, ordered after Home Assistant, that reads a Nix attrset
and applies it through Home Assistant's REST and websocket APIs,
idempotently, on every deploy. Pre-seeding `.storage` JSON was rejected:
the schema is internal and Home Assistant rewrites it. It covers:

- Onboarding: the owner account, with its password from sops, and the
  remaining onboarding steps, so the UI never shows the setup wizard.
- Integrations: each declared config flow is run when no entry for it
  exists, answering each step from Nix. Secrets come from files at run
  time. When a declared flow's inputs change, its entry is removed and
  recreated.
- Areas, device names and areas, and entity names and IDs. Devices are
  matched by registry identifier (`zwave_js` `<home id>-<node id>`).
  Automations reference only the entity IDs this table fixes, never
  generated ones.
- Backup settings (open question 6).

It logs in with the owner's credentials on each run and revokes its
refresh token when done, so no long-lived token is stored. It removes
nothing it did not declare.

One gap stays: `mobile_app` entries are created by the phone when the
companion app registers, and cannot exist before that. The reconciler
names the phone's device and entities once it has registered.

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

**Completes ahead of Plan 02, as a documented exception** to
`plan-sequencing-discipline`'s contiguous-prefix rule, as Plans 03 to
05 did. The owner decided (2026-11-26) that this plan's subtasks merge
regardless of Plan 02's status, because nothing in it depends on Plan 02
(the receiver comparison) or the other way round.

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
6. **Backing up Home Assistant's state.** Decided (2026-11-26): Home
   Assistant's own backup, scheduled by the reconciler, and its backup
   directory picked up by the NAS. See 6.20.
7. **Where the NVM backup lives.** Decided (2026-11-26): in the repo,
   sops binary mode, encrypted for the owner's four workstations and no
   host. See 6.1.
8. **Expiry length.** 18 h is proposed; it only re-arms with a
   notification, so erring short is cheap.

## Subtasks

### Phase 1: foundation on corehub

- [x] **6.1 Stick on corehub.** Move the ZW090 to corehub. Record its
      `/dev/serial/by-id` path and the USB port it is on. Re-run the
      read-only inventory from the stick's final position and record the
      alive/dead counts here, since dead nodes were measured from
      daytona. Store the NVM backup per open question 7. Nothing is
      installed yet.

      Done 2026-11-26. The stick is
      `/dev/serial/by-id/usb-0658_0200-if00`, on USB bus 3 port 3
      (`pci-0000:05:00.4-usb-0:3:1.0`), an xHCI controller. It
      enumerates at 12M with `cdc_acm` and needed no USB 2 workaround.
      daytona's script was unreachable, so the inventory was rewritten as
      `scripts/zwave-inventory.cjs`. Run it while nothing else holds the
      port.

      From corehub: 23 mains-powered alive, 26 mains-powered dead, 24
      battery asleep, 2 FLiRS dead. All 19 from daytona answer, plus
      four more:

      | Node | Device                     | Note                          |
      | ---- | -------------------------- | ----------------------------- |
      | 24   | GE 14287 in-wall fan speed | was dead from daytona         |
      | 46   | Inovelli NZW30             | was dead from daytona         |
      | 52   | Inovelli NZW30             | was dead from daytona         |
      | 37   | unknown                    | alive, interview stalls       |

      Node 37 sends a Binary Switch report about once a second but never
      gets past the protocol-info stage of its interview; look at it in
      6.7. Still dead: 4, 5, 6, 8, 9, 18, 20, 21, 40, 55, 100, 101 and the
      barrier nodes 65-95. The controller still reports no SUC after
      three zwave-js runs.

      NVM backup: `modules/secrets/zwave/nvm-d4558e0a-20261126.bin`
      (256 KiB raw, sha256 `71139129…a4b4ac37`), taken at the start of
      the final run. Successive backups differ in a few bytes that the
      controller updates itself during traffic. Decrypt with
      `sops decrypt --input-type binary --output-type binary`.
- [x] **6.2 Secrets.** New sops entries: zwave-js S0 and S2 keys
      (generated fresh), Mosquitto passwords for `homeassistant`,
      `frigate` and `nvr-watchdog`, and the Home Assistant owner's
      password for 6.19. They go in `secrets.yaml` like every other
      secret, readable by every host, by the owner's decision
      (2026-11-26).
- [x] **6.3 Mosquitto.** `services.mosquitto` on corehub: one listener on
      1883, LAN-reachable for nvrhub, password auth per user from 6.2,
      no anonymous access. Firewall opening for 1883 only.
- [x] **6.4 zwave-js.** `services.zwave-js` on corehub against the
      by-id path from 6.1, keys from 6.2 via `secretsConfigFile`, server
      on loopback only (Home Assistant is the only client). Verify: the
      server starts and reports home ID `d4558e0a` and the 23 live nodes.
- [x] **6.5 Home Assistant.** `services.home-assistant` on corehub, with
      `extraComponents` for `zwave_js`, `mqtt`, `mobile_app` and the
      defaults; the Frigate custom component; loopback bind; the
      `ha.int.fredsystems.org` vhost and AdGuard rewrite through
      corehub's `migratedVhosts`; no `automations.yaml` include. Verify:
      the UI loads over TLS. Onboarding is 6.19's job.
- [x] **6.6 Monitoring.** A blackbox probe for `ha.int.fredsystems.org`,
      and alert rules with tests for Home Assistant, zwave-js and
      Mosquitto being down, in the style of
      `modules/monitoring/master/alert-rules/frigate-alerts.yaml`.

      Done 2026-11-26, deployed by the owner with `colmena apply`. All
      four units active; `https://ha.int.fredsystems.org/` answers 200
      and its probe succeeds. The alert is
      `HomeAutomationUnitNotActive`: SystemdUnitFailed already covers
      failing and flapping, so it covers a unit that is just not running.
- [x] **6.19 Reconciler.** Added when the owner chose it (2026-11-26),
      numbered after the existing subtasks so none are renumbered. A
      NixOS module whose options take the onboarding, integration,
      area, device and entity tables, and a oneshot that applies them
      as described in "Home Assistant's configuration is declarative".
      Tests: a NixOS VM test running Home Assistant from corehub's
      nixpkgs and Mosquitto. It onboards, creates the `mqtt` entry, and
      renames an MQTT-discovered device and its entity. A second run
      changes nothing.

      Done 2026-11-26. zwave_js is not in the VM test: the mock driver
      lacks controller calls Home Assistant makes while loading the
      entry. The test also covers a Home Assistant restart, no leftover
      refresh tokens, and a changed MQTT password recreating the entry
      with names kept. On corehub the first run onboarded `fred`, created
      the `mqtt` and `zwave_js` entries, removed onboarding's
      `google_translate`, `shopping_list` and `met` entries and its three
      default areas, and set the backup schedule (13 changes, 0
      warnings). Entries created from configuration.yaml (`sun`) are kept.
- [ ] **6.20 Backups.** Home Assistant's automatic backup, set by the
      reconciler (daily, database included, a few local copies), and its
      backup directory added to what the NAS pulls from corehub.

      Repo side done 2026-11-26: daily at 02:30, seven kept, unencrypted
      in `/var/lib/hass/backups`, watched by `backupFreshness`. A manual
      run made a 260 KiB `.tar` and the freshness metric reads it. Still
      open: the NAS job pulling `corehub:/var/lib/hass/backups`, which
      is configured on the NAS, not in this repository.

### Phase 2: devices

- [x] **6.7 Adopt the network.** The reconciler creates the Z-Wave JS
      entry against the 6.4 server. Expect the 23 live nodes from the 6.1
      inventory with model and manufacturer, unnamed.

      Done 2026-11-26. Ten minutes after first start, the 22 nodes that
      were fully interviewed in 6.1 have model and entities: 7 lights, 2
      fans (24, 43), 13 switches. Node 37 is still uninterviewed; the
      other 52 are dead or asleep and have no model.
- [ ] **6.8 Identify every switch.** With the owner at the house:
      Home Assistant's logbook shows which node reports when a switch is
      flipped, so he flips each switch in turn and the node is named for
      its room and load. The plug-in switches (7, 44) are identified by
      toggling them from Home Assistant instead. The result is a Nix
      device table (node, area, name, entity ID) in corehub's config,
      not names typed into the UI.
- [ ] **6.9 Dead and ghost nodes.** Deferred by the owner (2026-11-26).
      Remove the "Secure Barrier Add-on" ghosts and other confirmed-dead
      nodes with "remove failed node"; find out whether fan controllers
      9, 18 and 24 still physically exist. The garage controller itself
      is re-included securely in Plan 07, not here.

      Five wall switches still work their load by hand but have left the
      Z-Wave network (owner, 2026-11-27):

      | Load                    | Area             | Node             |
      | ----------------------- | ---------------- | ---------------- |
      | Office Light            | Office           | unknown          |
      | Office Fan              | Office           | unknown          |
      | Master Bedroom Fan      | Master Bedroom   | unknown          |
      | Upstairs Hallway Light  | Upstairs Hallway | unknown          |
      | Dining Room Light       | Kitchen          | 56               |

      Node 56 is known because Kitchen Overhead Lights (97) still has it
      in its association group (6.21). Five replacement switches arrive
      2026-11-27; the owner installs them as he gets to them. Each is
      included (S2 where the switch supports it), added to the device
      table in `devices.nix`, and its dead node removed with "remove
      failed node", along with its place in any association group.

- [ ] **6.21 Switch associations.** Added 2026-11-27, numbered after
      the existing subtasks. Some wall switches command other devices
      directly through a Z-Wave association group, which is what the
      owner calls a scene: the lights follow the switch without the hub,
      so they keep working with Home Assistant or zwave-js down. Home
      Assistant has no editor for these, but zwave-js-server reads and
      writes them (`controller.get_associations`,
      `controller.add_associations`, `controller.remove_associations`),
      so they become a table in `devices.nix` (switch node, group,
      target nodes) applied by the reconciler, which adds what is missing
      and removes what is not declared. Group 1 (Lifeline, to the
      controller) is never touched. As read from zwave-js on 2026-11-27:

      | Switch (node)                | Group          | Targets now            | Wanted                          |
      | ---------------------------- | -------------- | ---------------------- | ------------------------------- |
      | Kitchen Overhead Lights (97) | 2 "BASIC SET"  | 56 (dead), 53          | 53 and the new Dining Room Light |
      | Master Bedroom Light (19)    | 2 "Local Load" | 13                     | 13 and Bed Lamp (7)             |
      | Living Room Light (42)       | 2 "Local Load" | 44, 45 (no such node)  | 44 and a second lamp plug       |

      Each group takes at most 5 targets. The kitchen row waits on the
      Dining Room Light's replacement (6.9), the living room's second
      plug on the owner finding a spare. The dimmers' group 3 ("Double
      Tap") reports to the controller, so a double tap can trigger an
      automation.

### Phase 3: Frigate

- [x] **6.10 Frigate MQTT.** Enable MQTT in `hosts/linux/nvrhub/frigate.nix`
      against corehub's broker, password via `LoadCredential=`.
- [x] **6.11 Frigate integration.** A dedicated Frigate user for Home
      Assistant (role decided at activation), and the integration
      configured against `https://nvr.int.fredsystems.org`.

      Done 2026-11-26 (6.10 and 6.11). Frigate publishes to the broker as
      `frigate` (`frigate/available` is `online`). Its users live in its
      database, so `hosts/linux/nvrhub/frigate-users.nix` keeps a
      `homeassistant` login, role viewer, in step with sops through the
      loopback admin listener. The reconciler created the integration,
      and Home Assistant has all 7 cameras, 63 switches and 189 sensors.
      Viewer covers reading and MQTT switching. PTZ and exports would
      need admin.

      Then, by the owner's decisions (2026-11-26): indoor cameras
      (kitchen, living_room, office, upstairs_hall, inside_garage) track
      only person, dog and cat in Frigate; Home Assistant keeps a lean set
      of each camera's entities enabled (`cameras.nix`), down from about
      44 per camera; and the cameras are placed in areas, with a new
      Garage area downstairs. Live video comes from a go2rtc restream on
      nvrhub (Plan 08, 8.6).
- [ ] **6.12 Verify control.** Toggling an indoor camera's review switch
      in Home Assistant flips it in Frigate, and a Frigate restart
      returns it to the Nix default.

### Owner's automations

Requested 2026-11-26, ahead of house mode, in
`hosts/linux/corehub/home-automation/automations.nix`:

- Front porch light on at a random moment 30 to 15 minutes before
  sunset, off 30 to 45 minutes after sunrise.
- Good Night (lights off in every area but Front Porch, and house mode
  `home_sleep`) and Good Morning (house mode `home_awake`, and
  lights on in Master Bedroom, Living Room and Kitchen, and the Master
  Vanity, added 2026-11-27). Scripts, run
  from Home Assistant or Siri through the HomeKit bridge, until house
  mode (6.15) gives them triggers.
- Garbage disposal off after 2 minutes continuously on.

### Phase 4: house mode

- [ ] **6.13 Presence.** The iOS companion app, the home zone, and the
      remote-access route from open question 1. The companion app is
      already registered (`device_tracker.iphone`, `person.fred`,
      `notify.mobile_app_iphone`, 2026-11-27); this adds the `away` and
      arrival transitions. Also a declared dashboard (owner,
      2026-11-27): the current house mode, and buttons that run Good
      Night and Good Morning.
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

      6.15-6.17 built 2026-11-27, ahead of presence by the owner's
      choice, in `hosts/linux/corehub/home-automation/house-mode.nix`
      and `hosts/linux/nvrhub/house-mode.nix`. Until 6.13 and 6.14, Good
      Night sets `home_sleep` and Good Morning sets `home_awake` and
      renews the expiry; both are deliberate, through Siri, the Home app
      or Home Assistant. The mode itself is not exposed to Apple Home.
      The mode is applied by publishing to Frigate's
      `frigate/<cam>/review_{alerts,detections}/set` topics, so it does
      not wait for the integration's switches after a Frigate restart.
      Expiry is a restored 18 h `timer`, and its notification goes to
      `notify.mobile_app_iphone`. The heartbeat is a retained epoch
      timestamp on `house/heartbeat` every minute, read by the
      `nvr-watchdog` broker user; the watchdog (a VM test,
      `.#checks.x86_64-linux.house-watchdog`) re-arms once the newest
      heartbeat it has seen is 5 minutes old, which rides out a Home
      Assistant restart. Frigate's loopback listener on 127.0.0.1:5000
      accepts websocket commands as admin, verified 2026-11-27 by
      turning the kitchen's alerts off and on. To verify after deploy:
      each script's effect on the indoor cameras in Frigate, a Frigate
      restart in `home_awake`, and Home Assistant stopped for 6 minutes
      in `home_awake`.
- [ ] **6.18 End-to-end test.** Every row of the transitions table, plus
      Home Assistant stopped while `home_awake`, Frigate restarted in
      each mode, the expiry, and a tag scanned while away (must do
      nothing).
