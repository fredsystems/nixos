# VM test for ./default.nix, run against the nixpkgs corehub uses (see
# flake/dev/checks.nix), so the Home Assistant APIs exercised are the ones
# that will be deployed.
#
# Home Assistant and Mosquitto. The reconciler onboards, creates the mqtt
# entry, prunes onboarding's leftovers, names a device that MQTT discovery
# registers and hides its switch, and places the light that wraps that switch,
# an entity with no device. Then it runs again, and after a Home Assistant restart, and must
# change nothing either time.
#
# zwave_js is not covered: zwave-js-server's --mock-driver gets the config
# flow as far as creating the entry, but lacks controller calls Home
# Assistant makes while loading it (getProvisioningEntries), so the entry
# never loads.
_:
let
  mqttPassword = "test-mqtt-password";
  rotatedPassword = "rotated-mqtt-password";
  ownerPassword = "test-owner-password";

  discovery = builtins.toJSON {
    name = "Relay";
    unique_id = "testdev_relay";
    command_topic = "test/relay/set";
    state_topic = "test/relay";
    device = {
      identifiers = [ "testdev" ];
      name = "Test device";
    };
  };
in
{
  name = "home-assistant-reconciler";

  nodes.machine =
    { lib, pkgs, ... }:
    {
      imports = [ ./default.nix ];

      virtualisation.memorySize = 2048;

      environment.etc."test/discovery.json".text = discovery;

      environment.systemPackages = [
        pkgs.mosquitto
        pkgs.jq
      ];

      services = {
        mosquitto = {
          enable = true;
          listeners = [
            {
              address = "127.0.0.1";
              port = 1883;
              settings.allow_anonymous = false;
              users.homeassistant = {
                password = mqttPassword;
                acl = [ "readwrite #" ];
              };
            }
          ];
        };

        home-assistant = {
          enable = true;
          extraComponents = [
            "default_config"
            "met"
            "google_translate"
            "radio_browser"
            "shopping_list"
            "mqtt"
          ];
          config = {
            default_config = { };
            homeassistant = {
              name = "Test";
              latitude = 0.0;
              longitude = 0.0;
              elevation = 0;
              unit_system = "metric";
              time_zone = "UTC";
              country = "US";
            };
            http.server_host = [ "127.0.0.1" ];
            # Shaped like corehub's light wrappers in devices.nix.
            template = [
              {
                light = [
                  {
                    name = "Lamp Light";
                    unique_id = "light_wrapper_lamp";
                    state = "{{ is_state('switch.lamp', 'on') }}";
                    availability = "{{ has_value('switch.lamp') }}";
                    turn_on = [
                      {
                        action = "switch.turn_on";
                        target.entity_id = "switch.lamp";
                      }
                    ];
                    turn_off = [
                      {
                        action = "switch.turn_off";
                        target.entity_id = "switch.lamp";
                      }
                    ];
                  }
                ];
              }
            ];
          };
        };

        home-assistant-reconciler = {
          enable = true;
          owner = {
            name = "Test Owner";
            username = "owner";
            passwordFile = pkgs.writeText "owner-password" ownerPassword;
          };
          secrets.mqtt-password = pkgs.writeText "mqtt-password" mqttPassword;

          integrations = {
            mqtt.steps.broker = {
              broker = "127.0.0.1";
              port = 1883;
              username = "homeassistant";
              password._secret = "mqtt-password";
            };
          };
          pruneIntegrations = true;

          areas = [
            "Office"
            "Kitchen"
          ];
          pruneAreas = true;

          floors = {
            Upstairs = {
              level = 1;
              areas = [ "Office" ];
            };
            Downstairs = {
              level = 0;
              areas = [ "Kitchen" ];
            };
          };
          pruneFloors = true;

          devices = [
            {
              identifier = [
                "mqtt"
                "testdev"
              ];
              name = "Lamp";
              area = "Office";
              entities = [
                {
                  domain = "switch";
                  entityId = "switch.lamp";
                  name = "Lamp";
                  hidden = true;
                }
              ];
            }
          ];

          entities = [
            {
              entityId = "light.lamp_light";
              area = "Office";
            }
          ];

          # The shape corehub uses, so a schema change in it fails here.
          backup = {
            automatic_backups_configured = true;
            create_backup = {
              agent_ids = [ "backup.local" ];
              include_database = true;
              password = null;
            };
            agents."backup.local".protected = false;
            retention = {
              copies = 3;
              days = null;
            };
            schedule = {
              recurrence = "daily";
              time = "02:30:00";
            };
          };
        };

      };
      # A rotated MQTT password changes the mqtt entry's declared steps.
      specialisation.rotated.configuration = {
        services.mosquitto.listeners = lib.mkForce [
          {
            address = "127.0.0.1";
            port = 1883;
            settings.allow_anonymous = false;
            users.homeassistant = {
              password = rotatedPassword;
              acl = [ "readwrite #" ];
            };
          }
        ];
        services.home-assistant-reconciler.secrets.mqtt-password = lib.mkForce (
          pkgs.writeText "mqtt-password" rotatedPassword
        );
      };
    };

  testScript = ''
    import json

    machine.wait_for_unit("mosquitto.service")
    machine.wait_for_open_port(1883)
    # Retained, so Home Assistant sees it as soon as the mqtt entry exists.
    machine.succeed(
        "mosquitto_pub -h 127.0.0.1 -u homeassistant -P ${mqttPassword} -r "
        "-t homeassistant/switch/testdev/config -f /etc/test/discovery.json"
    )

    machine.wait_for_unit("home-assistant.service")
    machine.wait_for_unit("home-assistant-reconciler.service", timeout=600)
    print(machine.succeed("journalctl -u home-assistant-reconciler.service -o cat"))

    with subtest("onboarding is finished"):
        steps = json.loads(machine.succeed("curl -sf http://127.0.0.1:8123/api/onboarding"))
        assert all(s["done"] for s in steps), steps

    with subtest("declared entries exist, onboarding's are pruned"):
        # Home Assistant writes .storage on a short delay, hence waiting.
        # sun is created from default_config in configuration.yaml, so it is
        # kept; the rest were started by onboarding and are removed.
        machine.wait_until_succeeds(
            "jq -e '[.data.entries[] | select(.source != \"ignore\" and .source != \"system\") "
            "| .domain] | sort == [\"mqtt\", \"sun\"]' /var/lib/hass/.storage/core.config_entries",
            timeout=60,
        )

    with subtest("areas are exactly the declared ones"):
        machine.wait_until_succeeds(
            "jq -e '[.data.areas[].name] | sort == [\"Kitchen\", \"Office\"]' /var/lib/hass/.storage/core.area_registry",
            timeout=60,
        )

    with subtest("floors exist, and their areas are on them"):
        machine.wait_until_succeeds(
            "jq -e '[.data.floors[] | {name, level}] | sort_by(.level) == "
            "[{\"name\": \"Downstairs\", \"level\": 0}, {\"name\": \"Upstairs\", \"level\": 1}]' "
            "/var/lib/hass/.storage/core.floor_registry",
            timeout=60,
        )
        machine.wait_until_succeeds(
            "jq -e '[.data.areas[] | {name, floor_id}] | sort_by(.name) == "
            "[{\"name\": \"Kitchen\", \"floor_id\": \"downstairs\"}, {\"name\": \"Office\", \"floor_id\": \"upstairs\"}]' "
            "/var/lib/hass/.storage/core.area_registry",
            timeout=60,
        )

    with subtest("the discovered device and entity are renamed"):
        machine.wait_until_succeeds(
            "jq -e '.data.entities[] | select(.entity_id == \"switch.lamp\" and .name == \"Lamp\")' "
            "/var/lib/hass/.storage/core.entity_registry",
            timeout=60,
        )
        machine.wait_until_succeeds(
            "jq -e '.data.devices[] | select(.name_by_user == \"Lamp\" and .area_id != null)' "
            "/var/lib/hass/.storage/core.device_registry",
            timeout=60,
        )

    with subtest("the wrapped switch is hidden, and its light wrapper placed"):
        machine.wait_until_succeeds(
            "jq -e '.data.entities[] | select(.entity_id == \"switch.lamp\" and .hidden_by == \"user\")' "
            "/var/lib/hass/.storage/core.entity_registry",
            timeout=60,
        )
        machine.wait_until_succeeds(
            "jq -e '.data.entities[] | select(.entity_id == \"light.lamp_light\" and .area_id == \"office\")' "
            "/var/lib/hass/.storage/core.entity_registry",
            timeout=60,
        )

    with subtest("backup settings are applied"):
        machine.wait_until_succeeds(
            "jq -e '.data.config.retention.copies == 3' /var/lib/hass/.storage/backup",
            timeout=60,
        )

    def refresh_tokens():
        # Settle past Home Assistant's storage write delay first.
        machine.sleep(15)
        return machine.succeed(
            "jq '[.data.refresh_tokens[] | select(.token_type == \"normal\")] | length' "
            "/var/lib/hass/.storage/auth"
        ).strip()

    with subtest("a second run changes nothing, and leaves no session behind"):
        before = refresh_tokens()
        machine.succeed("systemctl restart home-assistant-reconciler.service")
        out = machine.succeed("journalctl -u home-assistant-reconciler.service -o cat")
        last = [line for line in out.splitlines() if "done:" in line][-1]
        assert "done: 0 changes" in last, last
        after = refresh_tokens()
        assert before == after, f"refresh tokens went from {before} to {after}"

    with subtest("a Home Assistant restart re-runs it, still changing nothing"):
        machine.succeed("systemctl restart home-assistant.service")
        machine.wait_for_unit("home-assistant-reconciler.service", timeout=600)
        out = machine.succeed("journalctl -u home-assistant-reconciler.service -o cat")
        last = [line for line in out.splitlines() if "done:" in line][-1]
        assert "done: 0 changes" in last, last

    with subtest("changed steps recreate the entry, and the names come back"):
        machine.succeed(
            "/run/current-system/specialisation/rotated/bin/switch-to-configuration test"
        )
        machine.wait_for_unit("home-assistant-reconciler.service", timeout=600)
        out = machine.succeed("journalctl -u home-assistant-reconciler.service -o cat")
        assert "removed mqtt entry '127.0.0.1' (declaration changed)" in out, out
        last = [line for line in out.splitlines() if "done:" in line][-1]
        assert "0 warnings" in last, last
        machine.wait_until_succeeds(
            "jq -e '.data.entities[] | select(.entity_id == \"switch.lamp\" and .name == \"Lamp\")' "
            "/var/lib/hass/.storage/core.entity_registry",
            timeout=60,
        )
  '';
}
