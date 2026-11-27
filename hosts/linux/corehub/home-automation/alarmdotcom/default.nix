# Alarm.com (owner, 2026-11-27). The integration is packaged here
# (./package.nix), from the same nixpkgs as Home Assistant.
#
# The entry is created by hand, once, in Settings > Devices & Services:
# Alarm.com asks for a one-time code at login, which the reconciler cannot
# answer. After that the integration keeps a trusted-device token, and the
# entry lives in .storage and Home Assistant's backups. keepDomains stops the
# reconciler pruning it as undeclared.
#
# The devices are placed and named here, by Alarm.com's zone number. Each zone
# keeps its sensor, battery status and trouble sensor; the debug buttons and
# separate malfunction sensors (trouble covers them) are disabled. Entity IDs
# are set by unique ID, because Alarm.com builds the account's email address
# into the generated ones. None of this reaches Apple Home (../homekit.nix
# bridges Z-Wave devices only).
{ config, lib, ... }:
let
  # Alarm.com's system ID, the prefix of every device identifier.
  system = "96392102";

  # Zone number -> entity ID base, name and area (owner, 2026-11-27).
  zones = {
    "1" = {
      id = "garage_door";
      name = "Garage Door";
      area = "Garage";
    };
    "2" = {
      id = "siren_tamper";
      name = "Siren Tamper";
      area = "Laundry Room";
    };
    "3" = {
      id = "front_door";
      name = "Front Door";
      area = "Entrance Hallway";
    };
    "4" = {
      id = "living_room_motion";
      name = "Living Room Motion";
      area = "Living Room";
    };
    "5" = {
      id = "upstairs_motion";
      name = "Upstairs Motion";
      area = "Upstairs Hallway";
    };
    "6" = {
      id = "back_door";
      name = "Back Door";
      area = "Back Porch";
    };
    "7" = {
      id = "side_garage_door";
      name = "Side Garage Door";
      area = "Garage";
    };
    "8" = {
      id = "kitchen_window";
      name = "Kitchen Window";
      area = "Kitchen";
    };
    "9" = {
      id = "living_room_window";
      name = "Living Room Window";
      area = "Living Room";
    };
    "10" = {
      id = "master_bedroom_window";
      name = "Master Bedroom Window";
      area = "Master Bedroom";
    };
    "11" = {
      id = "office_window";
      name = "Office Window";
      area = "Office";
    };
    # Alarm.com calls these "Sparebed": the spare bedroom is the office.
    "12" = {
      id = "office_window_2";
      name = "Office Window 2";
      area = "Office";
    };
    "13" = {
      id = "office_window_3";
      name = "Office Window 3";
      area = "Office";
    };
    "14" = {
      id = "master_bathroom_window";
      name = "Master Bathroom Window";
      area = "Master Bathroom";
    };
    # The panel itself.
    "127" = {
      id = "alarm_panel";
      name = "Alarm Panel";
      area = null;
      domain = "alarm_control_panel";
    };
  };

  # Unnamed zones and the two key fobs: every entity disabled.
  ignored = [
    "17"
    "18"
    "19"
    "20"
    "21"
    "22"
    "23"
    "24"
  ];

  zone =
    n: z:
    let
      kept = [
        {
          domain = z.domain or "binary_sensor";
          uniqueId = "${system}-${n}";
          entityId = "${z.domain or "binary_sensor"}.${z.id}";
        }
        {
          domain = "sensor";
          uniqueId = "${system}-${n}_Battery Status";
          entityId = "sensor.${z.id}_battery_status";
        }
        {
          domain = "binary_sensor";
          uniqueId = "${system}-${n}_trouble";
          entityId = "binary_sensor.${z.id}_trouble";
        }
      ];
    in
    {
      identifier = [
        "alarmdotcom"
        "${system}-${n}"
      ];
      inherit (z) name area;
      entities = kept;
      keepEntities = map (e: e.entityId) kept;
    };
in
{
  services.home-assistant.customComponents = [
    (config.services.home-assistant.unstablePkgs.callPackage ./package.nix { })
  ];

  services.home-assistant-reconciler = {
    keepDomains = [ "alarmdotcom" ];

    devices =
      lib.mapAttrsToList zone zones
      ++ map (n: {
        identifier = [
          "alarmdotcom"
          "${system}-${n}"
        ];
        keepEntities = [ ];
      }) ignored;
  };
}
