# Automations and scripts, declared here rather than in the UI, so the UI
# shows them read-only. agent-docs/plans/PLAN_06_HOME_ASSISTANT.md.
#
# Lights are targeted by area where the intent is "the lights in these
# rooms", so a light added to ./devices.nix later is covered without editing
# this file. Area IDs are the area names slugged, as Home Assistant makes them.
{ config, lib, ... }:
let
  slug = name: lib.toLower (lib.replaceStrings [ " " ] [ "_" ] name);
  areas = map slug config.services.home-assistant-reconciler.areas;

  # A random delay of 0 to 15 minutes, in seconds, chosen each time.
  jitter = {
    delay.seconds = "{{ range(0, 901) | random }}";
  };
in
{
  services.home-assistant.config = {
    automation = [
      # On between 30 and 15 minutes before sunset, off between 30 and 45
      # minutes after sunrise: the sun trigger fires at the window's start
      # and the jitter places the switch somewhere in its first 15 minutes,
      # so the porch does not switch at the same minute every day.
      {
        id = "front_porch_light_on_before_sunset";
        alias = "Front porch light on before sunset";
        triggers = [
          {
            trigger = "sun";
            event = "sunset";
            offset = "-00:30:00";
          }
        ];
        actions = [
          jitter
          {
            action = "light.turn_on";
            target.entity_id = "light.front_porch_light";
          }
        ];
      }
      {
        id = "front_porch_light_off_after_sunrise";
        alias = "Front porch light off after sunrise";
        triggers = [
          {
            trigger = "sun";
            event = "sunrise";
            offset = "00:30:00";
          }
        ];
        actions = [
          jitter
          {
            action = "light.turn_off";
            target.entity_id = "light.front_porch_light";
          }
        ];
      }

      # A garbage disposal left running is a fault, not a use.
      {
        id = "garbage_disposal_off_after_2_minutes";
        alias = "Garbage disposal off after 2 minutes";
        triggers = [
          {
            trigger = "state";
            entity_id = "switch.garbage_disposal";
            to = "on";
            for.minutes = 2;
          }
        ];
        actions = [
          {
            action = "switch.turn_off";
            target.entity_id = "switch.garbage_disposal";
          }
        ];
      }
    ];

    # Run from Home Assistant, or from Siri and the Home app through the
    # HomeKit bridge. House mode (Plan 06, 6.15) will call these too.
    script = {
      good_night = {
        alias = "Good Night";
        icon = "mdi:weather-night";
        sequence = [
          {
            action = "light.turn_off";
            target.area_id = lib.remove "front_porch" areas;
          }
        ];
      };

      good_morning = {
        alias = "Good Morning";
        icon = "mdi:weather-sunny";
        sequence = [
          {
            action = "light.turn_on";
            target.area_id = [
              "master_bedroom"
              "living_room"
              "kitchen"
            ];
          }
        ];
      };
    };
  };

  assertions = [
    {
      assertion = lib.all (a: lib.elem a areas) [
        "front_porch"
        "master_bedroom"
        "living_room"
        "kitchen"
      ];
      message = "corehub: an area automations.nix targets is no longer declared in devices.nix.";
    }
  ];
}
