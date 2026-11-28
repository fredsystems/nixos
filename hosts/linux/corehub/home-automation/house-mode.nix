# House mode: Away, Home or Asleep, and what it does to the indoor
# cameras. agent-docs/plans/PLAN_06_HOME_ASSISTANT.md, "House mode" and
# 6.15-6.17.
#
# The indoor cameras' review alerts and detections are off in Home and
# on in the other two modes. Detection and recording are never touched.
# Modes change through Good Night and Good Morning (./automations.nix), by
# hand in Home Assistant, and with person.fred (6.13): Away once he has
# been out of the home zone for 5 minutes, Home when he comes back
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
# - Home falls to Asleep after 18 hours without renewal.
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

  # The plan's away, home_awake and home_sleep, under the names the UI
  # shows, which are the selector's actual values.
  modes = {
    away = "Away";
    awake = "Home";
    asleep = "Asleep";
  };

  mode = "input_select.house_mode";
  expiry = "timer.house_awake_expiry";
  person = "person.fred";

  # Fred known to be somewhere other than home. Unknown and unavailable are
  # not "away": they are Home Assistant or the app glitching, or not yet
  # restored at start.
  knownAway = "states('${person}') not in ['home', 'unknown', 'unavailable']";

  fullExpiry = "18:00:00";

  # Alarm.com's panel (./alarmdotcom). Armed STAY only, never AWAY.
  alarm = "alarm_control_panel.alarm_panel";

  # Every option a script selects on the house mode, however nested, so a
  # misspelt mode fails the build rather than the script at run time.
  scriptModes =
    let
      collect =
        v:
        if lib.isList v then
          lib.concatMap collect v
        else if lib.isAttrs v then
          lib.optional (
            (v.action or null) == "input_select.select_option"
            && lib.elem mode (lib.toList (v.target.entity_id or [ ]))
          ) v.data.option
          ++ lib.concatMap collect (lib.attrValues v)
        else
          [ ];
    in
    collect (lib.attrValues config.services.home-assistant.config.script);

  # Every action anywhere in the automations and scripts, however nested.
  allActions =
    let
      collect =
        v:
        if lib.isList v then
          lib.concatMap collect v
        else if lib.isAttrs v then
          # `service` is the older spelling of `action`, still accepted.
          lib.filter lib.isString [
            (v.action or null)
            (v.service or null)
          ]
          ++ lib.concatMap collect (lib.attrValues v)
        else
          [ ];
    in
    collect [
      config.services.home-assistant.config.automation
      (lib.attrValues config.services.home-assistant.config.script)
    ];
in
{
  # The owner's person, made at onboarding, follows the iPhone and nothing
  # else; the reconciler removes any other tracker added in the UI.
  services.home-assistant-reconciler.persons.${config.services.home-assistant-reconciler.owner.name}.deviceTrackers =
    [ "device_tracker.iphone" ];

  services.home-assistant.config = {
    # No `initial`, so the mode survives a restart. The first option is what
    # a new install starts in, and what a restored value that is no longer an
    # option becomes: Away, which is armed.
    input_select.house_mode = {
      name = "House mode";
      icon = "mdi:home-account";
      options = with modes; [
        away
        awake
        asleep
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
                    # Disarm only in Home, never with Fred known away (a
                    # dashboard selection cannot bypass the presence
                    # rule), and not at start with the expiry run out
                    # while Home Assistant was down (that is Asleep, set
                    # by house_mode_expired_while_down). Anything else,
                    # including a mode not yet restored, arms.
                    payload = ''
                      {{ 'OFF' if is_state('${mode}', '${modes.awake}')
                           and not (${knownAway})
                           and not (trigger.platform == 'homeassistant' and is_state('${expiry}', 'idle'))
                         else 'ON' }}'';
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
                state = modes.awake;
              }
            ];
            "then" = [
              {
                # The full duration: without it a timer restored after a
                # restart would resume its remaining time.
                action = "timer.start";
                target.entity_id = expiry;
                data.duration = fullExpiry;
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
            state = modes.awake;
          }
        ];
        actions = [
          {
            action = "input_select.select_option";
            target.entity_id = mode;
            data.option = modes.asleep;
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

      # Away arms the alarm STAY, never AWAY: AWAY would turn on the indoor
      # motion sensors, and the pets stay home (owner, 2026-11-27). Fires on
      # leaving and on choosing Away by hand; an alarm already armed is
      # left as it is.
      {
        id = "house_mode_away_arms";
        alias = "House mode: arm the alarm (stay) when Away";
        # restart: a panel recovering during the wait below starts a fresh
        # attempt instead of being dropped; the conditions still apply.
        mode = "restart";
        triggers = [
          {
            trigger = "state";
            entity_id = mode;
            to = modes.away;
          }
          # A panel that was unavailable when the house went Away is armed
          # once it is back; otherwise it would stay disarmed for the whole
          # absence.
          {
            trigger = "state";
            entity_id = alarm;
            from = [
              "unavailable"
              "unknown"
            ];
          }
        ];
        conditions = [
          {
            condition = "state";
            entity_id = mode;
            state = modes.away;
          }
          {
            condition = "state";
            entity_id = alarm;
            state = "disarmed";
          }
        ];
        actions = [
          {
            action = "alarm_control_panel.alarm_arm_home";
            target.entity_id = alarm;
            continue_on_error = true;
          }
          # Judged by the panel's state, not the command's reply: Alarm.com
          # arms slowly (about 90 s) and its confirmation can time out first.
          {
            wait_template = "{{ is_state('${alarm}', 'armed_home') }}";
            timeout.minutes = 3;
            continue_on_timeout = true;
          }
          {
            "if" = [
              {
                condition = "template";
                # Still Away: arriving meanwhile disarms on purpose.
                value_template = "{{ is_state('${mode}', '${modes.away}') and not is_state('${alarm}', 'armed_home') }}";
              }
            ];
            "then" = [
              {
                action = "notify.mobile_app_iphone";
                data = {
                  title = "Alarm not armed";
                  message = "The house went Away but after 3 minutes the alarm is {{ states('${alarm}') }}. Arm it from the Alarm.com app.";
                  data.push.interruption-level = "time-sensitive";
                };
                continue_on_error = true;
              }
            ];
          }
        ];
      }

      # A Home expiry that ran out while Home Assistant was down finishes
      # during startup, before automations exist, so house_mode_awake_expiry
      # never sees it. An idle timer in Home at start means exactly that.
      {
        id = "house_mode_expired_while_down";
        alias = "House mode: home awake expired while Home Assistant was down";
        triggers = [
          {
            trigger = "homeassistant";
            event = "start";
          }
        ];
        conditions = [
          {
            condition = "state";
            entity_id = mode;
            state = modes.awake;
          }
          {
            condition = "state";
            entity_id = expiry;
            state = "idle";
          }
        ];
        actions = [
          {
            action = "input_select.select_option";
            target.entity_id = mode;
            data.option = modes.asleep;
          }
          {
            action = "notify.mobile_app_iphone";
            data = {
              title = "House re-armed";
              message = "Home awake ran out while Home Assistant was down, so the indoor cameras are alerting again. Run Good Morning to turn them off.";
            };
            continue_on_error = true;
          }
        ];
      }

      # Home is for when Fred is home: chosen on the dashboard while he is
      # away, it goes back to Away (and house_mode_apply never disarmed).
      {
        id = "house_mode_home_needs_fred";
        alias = "House mode: Home needs Fred home";
        triggers = [
          {
            trigger = "state";
            entity_id = mode;
            to = modes.awake;
          }
        ];
        conditions = [
          {
            condition = "template";
            value_template = "{{ ${knownAway} }}";
          }
        ];
        actions = [
          {
            action = "input_select.select_option";
            target.entity_id = mode;
            data.option = modes.away;
          }
          {
            action = "notify.mobile_app_iphone";
            data = {
              title = "House stays armed";
              message = "Home can only be chosen while you are home; the house is back to Away.";
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
            entity_id = "zone.home";
            to = "0";
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
          # Time out of the home zone, from zone.home's count of people in
          # it (only Fred has a person): unlike person.fred's last change,
          # it does not restart when he enters another zone.
          {
            condition = "template";
            value_template = ''
              {{ states('zone.home') == '0'
                 and ${knownAway}
                 and now() - states.zone.home.last_changed > timedelta(minutes=5) }}'';
          }
          {
            condition = "not";
            conditions = [
              {
                condition = "state";
                entity_id = mode;
                state = modes.away;
              }
            ];
          }
        ];
        actions = [
          {
            action = "input_select.select_option";
            target.entity_id = mode;
            data.option = modes.away;
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
            state = modes.away;
          }
        ];
        actions = [
          {
            action = "input_select.select_option";
            target.entity_id = mode;
            data.option = modes.awake;
          }
          # Arriving disarms the alarm that leaving armed (owner,
          # 2026-11-27), judged by the panel's state rather than the
          # command's reply (a timed-out command can still disarm): one
          # retry after a minute if Fred is still home, then a notification.
          {
            action = "alarm_control_panel.alarm_disarm";
            target.entity_id = alarm;
            continue_on_error = true;
          }
          {
            wait_template = "{{ is_state('${alarm}', 'disarmed') }}";
            timeout.minutes = 1;
            continue_on_timeout = true;
          }
          {
            "if" = [
              {
                condition = "template";
                # Still Home: Good Night meanwhile arms on purpose.
                value_template = "{{ is_state('${mode}', '${modes.awake}') and not is_state('${alarm}', 'disarmed') and is_state('${person}', 'home') }}";
              }
            ];
            "then" = [
              {
                action = "alarm_control_panel.alarm_disarm";
                target.entity_id = alarm;
                continue_on_error = true;
              }
              {
                wait_template = "{{ is_state('${alarm}', 'disarmed') }}";
                timeout.minutes = 2;
                continue_on_timeout = true;
              }
            ];
          }
          {
            "if" = [
              {
                condition = "template";
                value_template = "{{ is_state('${mode}', '${modes.awake}') and not is_state('${alarm}', 'disarmed') }}";
              }
            ];
            "then" = [
              {
                action = "notify.mobile_app_iphone";
                data = {
                  title = "Alarm still armed";
                  message = "You arrived home but the alarm is still {{ states('${alarm}') }}. Disarm it from the Alarm.com app or Good Morning.";
                  data.push.interruption-level = "time-sensitive";
                };
                continue_on_error = true;
              }
            ];
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
                state = modes.awake;
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
              message = "Seen while the house is {{ states('${mode}') | lower }}.";
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
      # AWAY turns on the indoor motion sensors, which the pets trip.
      assertion = !(lib.elem "alarm_control_panel.alarm_arm_away" allActions);
      message = "corehub: an automation or script arms the alarm AWAY; only STAY (alarm_arm_home) is allowed, for the pets.";
    }
    {
      assertion = lib.all (o: lib.elem o (lib.attrValues modes)) scriptModes;
      message = "corehub: a script sets house mode to ${toString scriptModes}, not one of ${toString (lib.attrValues modes)}.";
    }
    {
      assertion = indoor != [ ];
      message = "corehub: house mode found no indoor cameras in nvrhub's Frigate config.";
    }
  ];
}
