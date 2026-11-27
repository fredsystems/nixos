# The Z-Wave devices, by node. Plan 06, 6.8.
#
# Identified by the owner at the house on 2026-11-26. Each node's one control
# entity is named for its load, with an entity ID made from that name, and
# automations refer to those entity IDs. The device, the switch in the wall
# or the plug, is named for the load plus what kind of device it is.
#
# Nodes are matched by registry identifier "<home id>-<node id>", the home ID
# being d4558e0a in decimal.
{ lib, ... }:
let
  homeId = "3562376714";

  slug = name: lib.toLower (lib.replaceStrings [ " " ] [ "_" ] name);

  kinds = {
    dimmer = "Dimmer";
    motionDimmer = "Motion Dimmer";
    motionSwitch = "Motion Switch";
    switch = "Switch";
    # The loads are already named "... Fan".
    fan = "Control";
    plug = "Plug";
  };

  domains = {
    dimmer = "light";
    motionDimmer = "light";
    motionSwitch = "switch";
    switch = "switch";
    fan = "fan";
    plug = "switch";
  };

  node = id: kind: area: name: {
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

  devices = [
    (node 7 "plug" "Master Bedroom" "Master Bedroom Bed Lamp")
    (node 13 "switch" "Master Bathroom" "Master Vanity")
    (node 16 "motionDimmer" "Master Bathroom" "Master Bathroom")
    (node 17 "motionSwitch" "Master Bathroom" "Master Bathroom Vent")
    (node 19 "dimmer" "Bedroom" "Bedroom Light")
    (node 23 "dimmer" "Server Room" "Server Room Light")
    (node 24 "fan" "Server Room" "Server Room Fan")
    (node 32 "motionDimmer" "Guest Bathroom" "Guest Bathroom Main Light")
    (node 33 "motionDimmer" "Guest Bathroom" "Guest Bathroom Second Light")
    (node 34 "motionSwitch" "Guest Bathroom" "Guest Bathroom Vent Fan")
    (node 38 "switch" "Stairs" "Stair Light")
    (node 41 "switch" "Entrance Hallway" "Entrance Hallway Light")
    (node 42 "dimmer" "Living Room" "Living Room Light")
    (node 43 "fan" "Living Room" "Living Room Fan")
    (node 44 "plug" "Living Room" "Living Room Lamp")
    (node 46 "switch" "Front Porch" "Front Porch Light")
    (node 48 "switch" "Laundry Room" "Laundry Room Light")
    (node 49 "switch" "Laundry Room" "Laundry Room Vent Fan")
    (node 50 "switch" "Back Porch" "Back Porch Light")
    (node 52 "switch" "Kitchen" "Garbage Disposal")
    (node 53 "dimmer" "Kitchen" "Kitchen Sink Light")
    (node 97 "switch" "Kitchen" "Kitchen Overhead Lights")
  ];
in
{
  services.home-assistant-reconciler = {
    inherit devices;
    areas = lib.unique (map (d: d.area) devices);
  };
}
