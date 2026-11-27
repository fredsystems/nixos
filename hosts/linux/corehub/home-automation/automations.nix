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
      #
      # A restart or an automation reload cancels the pending two minutes,
      # and the state trigger does not fire again for a disposal that is
      # already on. So a check every minute, at start and after a reload,
      # turns off a disposal that has been on two minutes by then.
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
          {
            trigger = "time_pattern";
            minutes = "/1";
          }
          {
            trigger = "homeassistant";
            event = "start";
          }
          {
            trigger = "event";
            event_type = "automation_reloaded";
          }
        ];
        conditions = [
          {
            condition = "state";
            entity_id = "switch.garbage_disposal";
            state = "on";
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
    # HomeKit bridge. Both set the house mode (./house-mode.nix): Good Night
    # arms the indoor cameras, Good Morning disarms them and renews the
    # 18-hour expiry, even when the mode is already home_awake.
    script = {
      good_night = {
        alias = "Good Night";
        icon = "mdi:weather-night";
        sequence = [
          {
            action = "input_select.select_option";
            target.entity_id = "input_select.house_mode";
            data.option = "home_sleep";
          }
          # Neither step is fatal to the other: a light that fails still
          # leaves the door locked, a lock out of reach the lights off.
          {
            action = "light.turn_off";
            target.area_id = lib.remove "front_porch" areas;
            continue_on_error = true;
          }
          # Good Night locks; nothing unlocks automatically.
          {
            action = "lock.lock";
            target.entity_id = "lock.front_door";
            continue_on_error = true;
          }
        ];
      };

      good_morning = {
        alias = "Good Morning";
        icon = "mdi:weather-sunny";
        sequence = [
          {
            action = "input_select.select_option";
            target.entity_id = "input_select.house_mode";
            data.option = "home_awake";
          }
          {
            action = "timer.start";
            target.entity_id = "timer.house_awake_expiry";
          }
          {
            action = "light.turn_on";
            target.area_id = [
              "master_bedroom"
              "living_room"
              "kitchen"
            ];
          }
          {
            action = "light.turn_on";
            target.entity_id = "light.master_vanity";
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
