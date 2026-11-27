# The Z-Wave devices, by node. Plan 06, 6.8.
#
# Identified by the owner at the house on 2026-11-26. Each node's one control
# entity is named for its load, with an entity ID made from that name, and
# automations refer to those entity IDs. The device, the switch in the wall
# or the plug, is named for the load plus what kind of device it is.
#
# Nodes are matched by registry identifier "<home id>-<node id>", the home ID
# being d4558e0a in decimal.
#
# An on/off switch or plug whose load is a light (lightSwitch, lampPlug) is
# also wrapped in a template light of the same name, light.<name>, so Apple
# Home and Siri treat it as a light. A template light rather than the `switch`
# light platform: that one copies the switch's registry ID when Home Assistant
# starts, so on a fresh install, before Z-Wave has created the switch, it gets
# no registry entry and cannot be given an area. The wrapper has no device, so
# it is given the switch's area directly, and the switch entity is hidden so
# each load shows once. The switch still works; automations may use either.
#
# Areas are grouped into floors. Office and Upstairs Hallway have no working
# device yet (Plan 06, 6.9), but are declared so the floor plan is complete.
{ config, lib, ... }:
let
  homeId = "3562376714";

  slug = name: lib.toLower (lib.replaceStrings [ " " ] [ "_" ] name);

  kinds = {
    dimmer = "Dimmer";
    motionDimmer = "Motion Dimmer";
    motionSwitch = "Motion Switch";
    switch = "Switch";
    lightSwitch = "Switch";
    lampPlug = "Plug";
    lock = "Lock";
    # The loads are already named "... Fan".
    fan = "Control";
  };

  domains = {
    dimmer = "light";
    motionDimmer = "light";
    motionSwitch = "switch";
    switch = "switch";
    lightSwitch = "switch";
    lampPlug = "switch";
    lock = "lock";
    fan = "fan";
  };

  wrapsAsLight = [
    "lightSwitch"
    "lampPlug"
  ];

  node = id: kind: area: name: rec {
    asLight = lib.elem kind wrapsAsLight;
    lightId = "light.${slug name}";
    device = {
      identifier = [
        "zwave_js"
        "${homeId}-${toString id}"
      ];
      name = "${name} ${kinds.${kind}}";
      inherit area;
      entities = [
        rec {
          domain = domains.${kind};
          inherit name;
          entityId = "${domain}.${slug name}";
          hidden = if asLight then true else null;
        }
      ];
    };
  };

  table = [
    (node 7 "lampPlug" "Master Bedroom" "Master Bedroom Bed Lamp")
    (node 13 "lightSwitch" "Master Bathroom" "Master Vanity")
    (node 16 "motionDimmer" "Master Bathroom" "Master Bathroom")
    (node 17 "motionSwitch" "Master Bathroom" "Master Bathroom Vent")
    (node 19 "dimmer" "Master Bedroom" "Master Bedroom Light")
    (node 23 "dimmer" "Server Room" "Server Room Light")
    (node 24 "fan" "Server Room" "Server Room Fan")
    (node 32 "motionDimmer" "Guest Bathroom" "Guest Bathroom Main Light")
    (node 33 "motionDimmer" "Guest Bathroom" "Guest Bathroom Second Light")
    (node 34 "motionSwitch" "Guest Bathroom" "Guest Bathroom Vent Fan")
    (node 38 "lightSwitch" "Stairs" "Stair Light")
    (node 41 "lightSwitch" "Entrance Hallway" "Entrance Hallway Light")
    (node 42 "dimmer" "Living Room" "Living Room Light")
    (node 43 "fan" "Living Room" "Living Room Fan")
    (node 44 "lampPlug" "Living Room" "Living Room Lamp")
    (node 46 "lightSwitch" "Front Porch" "Front Porch Light")
    (node 48 "lightSwitch" "Laundry Room" "Laundry Room Light")
    (node 49 "switch" "Laundry Room" "Laundry Room Vent Fan")
    (node 50 "lightSwitch" "Back Porch" "Back Porch Light")
    (node 52 "switch" "Kitchen" "Garbage Disposal")
    (node 53 "dimmer" "Kitchen" "Kitchen Sink Light")
    (node 97 "lightSwitch" "Kitchen" "Kitchen Overhead Lights")
    # Enbrighten 800 series dimmer, included with S2 Authenticated on
    # 2026-11-27, replacing node 56, which left the network (6.9).
    (node 103 "dimmer" "Kitchen" "Dining Room Light")
    # GE 800 series on/off switch, included with S2 Authenticated on
    # 2026-11-27, replacing the Office Light switch that left the network.
    (node 104 "lightSwitch" "Office" "Office Light")
    # Jasco 14314 fan speed control, included on 2026-11-27 (no S2), replacing
    # the Office Fan control that left the network.
    (node 105 "fan" "Office" "Office Fan")
    # Kwikset SmartCode 910 deadbolt, re-included with S0 as node 102 on
    # 2026-11-26 (it was node 81, included with the old, lost S0 key). See
    # ./zwave-js.nix for the device-file override its interview needs.
    #
    # Its other entities are disabled. Among them is "Current status of the
    # door", which reads Open whatever the door does: the Door Lock report has
    # a door-position field, the 910 has no door sensor, and it leaves the
    # field at 0, which means open. The lock-mode and local-protection
    # selectors go too. The battery and jam entities feed the alerts in
    # modules/monitoring/master/alert-rules/home-automation-alerts.yaml.
    (lib.recursiveUpdate (node 102 "lock" "Entrance Hallway" "Front Door") {
      device.keepEntities = [
        "lock.front_door"
        "sensor.front_door_lock_battery_level"
        "binary_sensor.front_door_lock_lock_jammed"
        "binary_sensor.front_door_lock_charge_battery_soon"
        "binary_sensor.front_door_lock_charge_battery_now"
        "sensor.node_102_node_status"
        "button.node_102_ping"
      ];
    })
  ];

  devices = map (n: n.device) table;
  lights = lib.filter (n: n.asLight) table;

  floors = {
    Upstairs = {
      level = 1;
      areas = [
        "Office"
        "Server Room"
        "Upstairs Hallway"
        "Master Bedroom"
        "Master Bathroom"
        "Guest Bathroom"
      ];
    };
    Downstairs = {
      level = 0;
      areas = lib.subtractLists floors.Upstairs.areas (lib.unique (map (d: d.area) devices));
    };
  };

  wrapper =
    n:
    let
      switch = (lib.head n.device.entities).entityId;
    in
    {
      inherit (lib.head n.device.entities) name;
      unique_id = "light_wrapper_${slug (lib.head n.device.entities).name}";
      state = "{{ is_state('${switch}', 'on') }}";
      availability = "{{ has_value('${switch}') }}";
      turn_on = [
        {
          action = "switch.turn_on";
          target.entity_id = switch;
        }
      ];
      turn_off = [
        {
          action = "switch.turn_off";
          target.entity_id = switch;
        }
      ];
    };
in
{
  services.home-assistant-reconciler = {
    inherit devices floors;
    # Every area on a floor, including ones other files add (cameras.nix).
    areas = lib.unique (
      lib.concatMap (f: f.areas) (lib.attrValues config.services.home-assistant-reconciler.floors)
    );
    pruneFloors = true;
    entities = map (n: {
      entityId = n.lightId;
      inherit (n.device) area;
    }) lights;
  };

  services.home-assistant.config.template = [ { light = map wrapper lights; } ];
}
