# House mode: away, home_awake or home_sleep, and what it does to the indoor
# cameras. agent-docs/plans/PLAN_06_HOME_ASSISTANT.md, "House mode" and
# 6.15-6.17.
#
# The indoor cameras' review alerts and detections are off in home_awake and
# on in the other two modes. Detection and recording are never touched.
# Modes change through Good Night and Good Morning (./automations.nix), by
# hand in Home Assistant, and with person.fred (6.13): away once he has
# been out of the home zone for 5 minutes, home_awake when he comes back
# while away, whatever the hour.
#
# The person follows the iPhone only (declared below). A person takes the
# latest report among its trackers, and the iPad, which stays home, would
# otherwise make him home while he is out, and so disarm the house.
# Disarming always needs him home, so Good Morning from a hotel through Siri
# does not disarm the house.
#
# Fails safe in three ways:
# - The mode is published straight to Frigate's MQTT command topics, not
#   through the integration's switches, and again whenever Frigate comes
#   online: Frigate restarts with review on, from its Nix config, and the
#   switches are unavailable for a moment around that.
# - home_awake falls to home_sleep after 18 hours without renewal.
# - Home Assistant publishes a heartbeat; nvrhub's house watchdog re-arms the
#   cameras when it stops (hosts/linux/nvrhub/house-mode.nix).
{
  config,
  inputs,
  lib,
  ...
}:
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
  person = "person.fred";
in
{
  # The owner's person, made at onboarding, follows the iPhone and nothing
  # else; the reconciler removes any other tracker added in the UI.
  services.home-assistant-reconciler.persons.${config.services.home-assistant-reconciler.owner.name}.deviceTrackers =
    [ "device_tracker.iphone" ];

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

      # A restart cancels a pending `for`, and a person already gone does not
      # change state again, so the same check also runs every few minutes
      # and at start. Unknown and unavailable are not "away": they are Home
      # Assistant or the app glitching, not the owner leaving.
      {
        id = "house_mode_leave";
        alias = "House mode: away when Fred leaves";
        triggers = [
          {
            trigger = "state";
            entity_id = person;
            from = "home";
            "for".minutes = 5;
          }
          {
            trigger = "time_pattern";
            minutes = "/5";
          }
          {
            trigger = "homeassistant";
            event = "start";
          }
        ];
        conditions = [
          {
            condition = "template";
            value_template = ''
              {{ states('${person}') not in ['home', 'unknown', 'unavailable']
                 and now() - states.${person}.last_changed > timedelta(minutes=5) }}'';
          }
          {
            condition = "not";
            conditions = [
              {
                condition = "state";
                entity_id = mode;
                state = "away";
              }
            ];
          }
        ];
        actions = [
          {
            action = "input_select.select_option";
            target.entity_id = mode;
            data.option = "away";
          }
        ];
      }

      # Arriving disarms, at any hour; Good Night arms again for the night,
      # and the 18 h expiry backs that up.
      {
        id = "house_mode_arrive";
        alias = "House mode: home awake when Fred arrives";
        triggers = [
          {
            trigger = "state";
            entity_id = person;
            to = "home";
          }
          {
            trigger = "homeassistant";
            event = "start";
          }
        ];
        conditions = [
          {
            condition = "state";
            entity_id = person;
            state = "home";
          }
          {
            condition = "state";
            entity_id = mode;
            state = "away";
          }
        ];
        actions = [
          {
            action = "input_select.select_option";
            target.entity_id = mode;
            data.option = "home_awake";
          }
        ];
      }

      # A person indoors while armed is pushed to the iPhone with Frigate's
      # snapshot, once per review item (owner, 2026-11-27). Review runs only
      # while armed, and indoors only people make review items
      # (nvrhub's frigate.nix), so an alert on an indoor camera is a person;
      # the mode is checked anyway. The image comes through the Frigate
      # integration's notification proxy.
      {
        id = "house_mode_person_indoors";
        alias = "House mode: notify of a person indoors while armed";
        mode = "parallel";
        triggers = [
          {
            trigger = "mqtt";
            topic = "frigate/reviews";
          }
        ];
        conditions = [
          {
            condition = "template";
            value_template = ''
              {{ trigger.payload_json.type == 'new'
                 and trigger.payload_json.after.severity == 'alert'
                 and trigger.payload_json.after.camera in ${builtins.toJSON indoor} }}'';
          }
          {
            condition = "not";
            conditions = [
              {
                condition = "state";
                entity_id = mode;
                state = "home_awake";
              }
            ];
          }
        ];
        actions = [
          {
            variables = {
              review = "{{ trigger.payload_json.after }}";
              room = "{{ review.camera | replace('_', ' ') | title }}";
            };
          }
          {
            action = "notify.mobile_app_iphone";
            data = {
              title = "Person in the {{ room }}";
              message = "Seen while the house is {{ states('${mode}') | replace('_', ' ') }}.";
              data = {
                image = "/api/frigate/notifications/{{ review.data.detections[0] }}/snapshot.jpg";
                tag = "{{ review.id }}";
                push.interruption-level = "time-sensitive";
              };
            };
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
