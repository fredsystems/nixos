# House mode: away, home_awake or home_sleep, and what it does to the indoor
# cameras. agent-docs/plans/PLAN_06_HOME_ASSISTANT.md, "House mode" and
# 6.15-6.17.
#
# The indoor cameras' review alerts and detections are off in home_awake and
# on in the other two modes. Detection and recording are never touched.
# Modes change through Good Night and Good Morning (./automations.nix), by
# hand in Home Assistant, and, once presence exists (6.13), on leaving and
# arriving.
#
# Fails safe in three ways:
# - The mode is published straight to Frigate's MQTT command topics, not
#   through the integration's switches, and again whenever Frigate comes
#   online: Frigate restarts with review on, from its Nix config, and the
#   switches are unavailable for a moment around that.
# - home_awake falls to home_sleep after 18 hours without renewal.
# - Home Assistant publishes a heartbeat; nvrhub's house watchdog re-arms the
#   cameras when it stops (hosts/linux/nvrhub/house-mode.nix).
{ inputs, lib, ... }:
let
  frigate = inputs.self.nixosConfigurations.nvrhub.config.services.frigate.settings;

  # nvrhub's frigate.nix gives exactly the indoor cameras their own
  # objects.track (person, dog, cat).
  indoor = lib.attrNames (lib.filterAttrs (_: c: (c.objects or { }) ? track) frigate.cameras);

  reviewTopics = lib.concatMap (cam: [
    "frigate/${cam}/review_alerts/set"
    "frigate/${cam}/review_detections/set"
  ]) indoor;

  mode = "input_select.house_mode";
  expiry = "timer.house_awake_expiry";
in
{
  services.home-assistant.config = {
    # No `initial`, so the mode survives a restart. The first option is what
    # a new install starts in: away, which is armed.
    input_select.house_mode = {
      name = "House mode";
      icon = "mdi:home-account";
      options = [
        "away"
        "home_awake"
        "home_sleep"
      ];
    };

    # Restored across restarts; one that ran out while Home Assistant was
    # down finishes when it starts.
    timer.house_awake_expiry = {
      name = "Home awake expiry";
      duration = "18:00:00";
      restore = true;
    };

    automation = [
      {
        id = "house_mode_apply";
        alias = "House mode: apply to the indoor cameras";
        mode = "queued";
        triggers = [
          {
            trigger = "state";
            entity_id = mode;
          }
          {
            trigger = "mqtt";
            topic = "frigate/available";
            payload = "online";
          }
          {
            trigger = "homeassistant";
            event = "start";
          }
        ];
        actions = [
          {
            repeat = {
              for_each = reviewTopics;
              sequence = [
                {
                  action = "mqtt.publish";
                  data = {
                    topic = "{{ repeat.item }}";
                    # Anything but home_awake, including a mode not yet
                    # restored, arms.
                    payload = "{{ 'OFF' if is_state('${mode}', 'home_awake') else 'ON' }}";
                  };
                }
              ];
            };
          }
        ];
      }

      {
        id = "house_mode_awake_expiry_start";
        alias = "House mode: start the home awake expiry";
        triggers = [
          {
            trigger = "state";
            entity_id = mode;
          }
        ];
        actions = [
          {
            "if" = [
              {
                condition = "state";
                entity_id = mode;
                state = "home_awake";
              }
            ];
            "then" = [
              {
                action = "timer.start";
                target.entity_id = expiry;
              }
            ];
            "else" = [
              {
                action = "timer.cancel";
                target.entity_id = expiry;
              }
            ];
          }
        ];
      }

      {
        id = "house_mode_awake_expiry";
        alias = "House mode: home awake expires";
        triggers = [
          {
            trigger = "event";
            event_type = "timer.finished";
            event_data.entity_id = expiry;
          }
        ];
        conditions = [
          {
            condition = "state";
            entity_id = mode;
            state = "home_awake";
          }
        ];
        actions = [
          {
            action = "input_select.select_option";
            target.entity_id = mode;
            data.option = "home_sleep";
          }
          {
            action = "notify.mobile_app_iphone";
            data = {
              title = "House re-armed";
              message = "Home awake ran 18 hours without renewal, so the indoor cameras are alerting again. Run Good Morning to turn them off.";
            };
            continue_on_error = true;
          }
        ];
      }

      # Read by nvrhub's house watchdog. Retained, so it reads the latest
      # without waiting; a stale one means Home Assistant or the broker is
      # gone.
      {
        id = "house_mode_heartbeat";
        alias = "House mode: heartbeat";
        triggers = [
          {
            trigger = "time_pattern";
            minutes = "/1";
          }
        ];
        actions = [
          {
            action = "mqtt.publish";
            data = {
              topic = "house/heartbeat";
              payload = "{{ now().timestamp() | int }}";
              retain = true;
            };
          }
        ];
      }
    ];
  };

  assertions = [
    {
      assertion = indoor != [ ];
      message = "corehub: house mode found no indoor cameras in nvrhub's Frigate config.";
    }
  ];
}
