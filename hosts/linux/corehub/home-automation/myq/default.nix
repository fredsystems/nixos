# MyQ, for the garage door (owner, 2026-11-27; Plan 06, 6.22). The
# integration is packaged here (./package.nix).
#
# The entry is created by hand, once, in Settings > Devices & Services: MyQ
# sends a one-time code by email or SMS at sign-in, which the reconciler
# cannot answer. After that the integration keeps and refreshes OAuth
# tokens, and the entry lives in .storage and Home Assistant's backups.
# keepDomains stops the reconciler pruning it as undeclared.
#
# The opener is placed in the Garage as Garage Door, its cover is
# cover.garage_door, and it keeps the door, its open sensor, the work light,
# faults and what last moved it; vacation mode and the cycle counts are
# disabled. The cover is its own Apple Home accessory (../homekit.nix), at
# the owner's choice.
{ config, ... }:
let
  # The opener's MyQ serial, its device identifier.
  serial = "CG08506DE365";
in
{
  services.home-assistant.customComponents = [
    (config.services.home-assistant.unstablePkgs.callPackage ./package.nix { })
  ];

  services.home-assistant-reconciler = {
    keepDomains = [ "myq" ];

    devices = [
      {
        identifier = [
          "myq"
          serial
        ];
        # Named for the door, with the cover under the device's name
        # (../devices.nix explains why).
        name = "Garage Door";
        area = "Garage";
        entities = [
          {
            domain = "cover";
            uniqueId = serial;
            entityId = "cover.garage_door";
            nameFromDevice = true;
          }
        ];
        keepEntities = [
          "cover.garage_door"
          "binary_sensor.garage_door_door_open"
          "binary_sensor.garage_door_work_light"
          "binary_sensor.garage_door_active_fault"
          "sensor.garage_door_last_activation_source"
        ];
      }
    ];
  };
}
