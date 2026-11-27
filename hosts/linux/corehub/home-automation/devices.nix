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
# also wrapped in a light entity of the same name, light.<name>, so Apple Home
# and Siri treat it as a light. Its switch entity stays; automations may use
# either.
{ lib, ... }:
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
    fan = "fan";
  };

  wrapsAsLight = [
    "lightSwitch"
    "lampPlug"
  ];

  node = id: kind: area: name: {
    asLight = lib.elem kind wrapsAsLight;
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
  ];

  devices = map (n: n.device) table;
in
{
  services.home-assistant-reconciler = {
    inherit devices;
    areas = lib.unique (map (d: d.area) devices);
  };

  services.home-assistant.config.light = map (n: {
    platform = "switch";
    inherit (lib.head n.device.entities) name;
    entity_id = (lib.head n.device.entities).entityId;
  }) (lib.filter (n: n.asLight) table);
}
