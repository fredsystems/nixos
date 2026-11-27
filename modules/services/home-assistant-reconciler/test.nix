# VM test for ./default.nix, run against the Home Assistant corehub runs:
# flake/dev/checks.nix imports corehub's home-automation/unstable.nix into the
# node, so the Home Assistant APIs exercised are the ones that will be
# deployed.
#
# Home Assistant and Mosquitto. The reconciler onboards, creates the mqtt
# entry, prunes onboarding's leftovers, names a device that MQTT discovery
# registers and hides its switch, places the light that wraps that switch,
# an entity with no device, and sets the trackers the owner's person follows. Then it runs again, and after a Home Assistant restart, and must
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

  # A second entity on the same device, which keepEntities must disable.
  discoveryExtra = builtins.toJSON {
    name = "Temperature";
    unique_id = "testdev_temperature";
    state_topic = "test/temperature";
    device.identifiers = [ "testdev" ];
  };

  # A device of two sensors for the disableEntities rule, which must disable
  # the humidity sensor and leave the pressure sensor.
  meterSensor =
    kind:
    builtins.toJSON {
      name = kind;
      unique_id = "meter_${kind}";
      state_topic = "test/meter/${kind}";
      device = {
        identifiers = [ "meter" ];
        name = "Meter";
      };
    };

  # A device whose declared rename clashes and whose keepEntities names the
  # wanted ID: its sensor must stay enabled under the ID it keeps.
  gadget = builtins.toJSON {
    name = "Level";
    unique_id = "gadget_level";
    state_topic = "test/gadget/level";
    device = {
      identifiers = [ "gadget" ];
      name = "Gadget";
    };
  };

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

  # Registers a phone the way the companion app does, as the owner, so the
  # test can check that its mobile_app entry survives pruning.
  registerPhone =
    pkgs: ownerUsername:
    pkgs.writers.writePython3Bin "register-test-phone"
      {
        libraries = [ pkgs.python3Packages.aiohttp ];
        flakeIgnore = [ "E501" ];
      }
      ''
        import asyncio

        import aiohttp

        URL = "http://127.0.0.1:8123"


        async def main():
            async with aiohttp.ClientSession() as s:
                flow = await (await s.post(URL + "/auth/login_flow", json={
                    "client_id": URL + "/",
                    "handler": ["homeassistant", None],
                    "redirect_uri": URL + "/",
                })).json()
                result = await (await s.post(
                    URL + "/auth/login_flow/" + flow["flow_id"],
                    json={
                        "client_id": URL + "/",
                        "username": "${ownerUsername}",
                        "password": "${ownerPassword}",
                    },
                )).json()
                tokens = await (await s.post(URL + "/auth/token", data={
                    "grant_type": "authorization_code",
                    "code": result["result"],
                    "client_id": URL + "/",
                })).json()
                headers = {"Authorization": "Bearer " + tokens["access_token"]}
                r = await s.post(
                    URL + "/api/mobile_app/registrations",
                    headers=headers,
                    json={
                        "device_id": "testphone",
                        "app_id": "io.robbie.HomeAssistant.test",
                        "app_name": "Home Assistant",
                        "app_version": "1.0",
                        "device_name": "Test Phone",
                        "manufacturer": "Test",
                        "model": "Test",
                        "os_name": "iOS",
                        "os_version": "18",
                        "supports_encryption": False,
                        "app_data": {},
                    },
                )
                assert r.status == 201, (r.status, await r.text())
                await s.post(URL + "/auth/revoke", data={"token": tokens["refresh_token"]})


        asyncio.run(main())
      '';
in
{
  name = "home-assistant-reconciler";

  nodes.machine =
    { lib, pkgs, ... }:
    {
      imports = [ ./default.nix ];

      virtualisation.memorySize = 2048;

      environment = {
        etc = {
          "test/discovery.json".text = discovery;
          "test/discovery-extra.json".text = discoveryExtra;
          "test/meter-humidity.json".text = meterSensor "humidity";
          "test/meter-pressure.json".text = meterSensor "pressure";
          "test/gadget.json".text = gadget;
        };
        systemPackages = [
          pkgs.mosquitto
          pkgs.jq
          (registerPhone pkgs "owner")
        ];
      };

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

          # Home Assistant starts on its defaults (all addresses), so the
          # first run must apply this, restart it, and confirm it.
          http = {
            server_host = [ "127.0.0.1" ];
            server_port = 8123;
            use_x_forwarded_for = true;
            trusted_proxies = [ "127.0.0.1/32" ];
          };
          owner = {
            name = "Test Owner";
            username = "owner";
            passwordFile = pkgs.writeText "owner-password" ownerPassword;
          };
          # Onboarding makes the owner's person. Its tracker is the phone the
          # test registers later; until then the person takes it anyway.
          persons."Test Owner".deviceTrackers = [ "device_tracker.test_phone" ];
          # Set, so the test proves that setting it cannot drop mobile_app.
          keepDomains = [ "sun" ];
          disableEntities = [
            {
              platform = "mqtt";
              uniqueId = "meter_hum.*";
            }
          ];
          secrets.mqtt-password = pkgs.writeText "mqtt-password" mqttPassword;

          integrations = {
            mqtt.steps.broker = {
              broker = "127.0.0.1";
              port = 1883;
              username = "homeassistant";
              password._secret = "mqtt-password";
              # A required section from Home Assistant 2026.11: plain TCP, no TLS
              # client certificate or CA, as before.
              other_settings = {
                set_client_cert = false;
                set_ca_cert = "off";
                transport = "tcp";
              };
            };
            # The options flow, as corehub's Frigate entry uses one. The test
            # device is announced under this prefix, so it is only discovered
            # if the option took effect.
            mqtt.optionsFlow.options.discovery_prefix = "discovered";
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
                "gadget"
              ];
              entities = [
                {
                  domain = "sensor";
                  uniqueId = "gadget_level";
                  entityId = "sensor.meter_pressure";
                }
              ];
              keepEntities = [ "sensor.meter_pressure" ];
            }
            # An entity ID that is already taken: the rename must warn and the
            # run carry on.
            {
              identifier = [
                "mqtt"
                "meter"
              ];
              entities = [
                {
                  domain = "sensor";
                  uniqueId = "meter_humidity";
                  entityId = "sensor.meter_pressure";
                }
              ];
            }
            {
              identifier = [
                "mqtt"
                "testdev"
              ];
              name = "Lamp";
              area = "Office";
              keepEntities = [ "switch.lamp" ];
              entities = [
                {
                  domain = "switch";
                  entityId = "switch.lamp";
                  name = "Lamp";
                  hidden = true;
                }
                # Never created: must warn, not fail the run.
                {
                  domain = "cover";
                  entityId = "cover.lamp_cover";
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
      # The disableEntities rule gone: what it disabled comes back.
      specialisation.unruled.configuration = {
        services.home-assistant-reconciler.disableEntities = lib.mkForce [ ];
      };

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
    machine.wait_for_unit("mosquitto.service")
    machine.wait_for_open_port(1883)
    # Retained, so Home Assistant sees it as soon as the mqtt entry exists.
    machine.succeed(
        "mosquitto_pub -h 127.0.0.1 -u homeassistant -P ${mqttPassword} -r "
        "-t discovered/switch/testdev/config -f /etc/test/discovery.json"
    )
    machine.succeed(
        "mosquitto_pub -h 127.0.0.1 -u homeassistant -P ${mqttPassword} -r "
        "-t discovered/sensor/testdev/config -f /etc/test/discovery-extra.json"
    )
    machine.succeed(
        "mosquitto_pub -h 127.0.0.1 -u homeassistant -P ${mqttPassword} -r "
        "-t discovered/sensor/gadget_level/config -f /etc/test/gadget.json"
    )
    for kind in ("humidity", "pressure"):
        machine.succeed(
            "mosquitto_pub -h 127.0.0.1 -u homeassistant -P ${mqttPassword} -r "
            f"-t discovered/sensor/meter_{kind}/config -f /etc/test/meter-{kind}.json"
        )

    machine.wait_for_unit("home-assistant.service")
    machine.wait_for_unit("home-assistant-reconciler.service", timeout=600)
    print(machine.succeed("journalctl -u home-assistant-reconciler.service -o cat"))

    with subtest("the HTTP settings were applied, then confirmed"):
        out = machine.succeed("journalctl -u home-assistant-reconciler.service -o cat")
        assert "http: applied new settings" in out, out
        assert "http: confirmed the new settings" in out, out
        machine.wait_until_succeeds(
            "jq -e '.data.pending == null and .data.stable.server_host == [\"127.0.0.1\"] "
            "and .data.stable.trusted_proxies == [\"127.0.0.1/32\"]' /var/lib/hass/.storage/http",
            timeout=60,
        )
        machine.succeed("ss -ltn | grep -q '127.0.0.1:8123 '")
        machine.fail("ss -ltn | grep -qE '(0.0.0.0|\\[::\\]):8123 '")

    with subtest("onboarding is finished"):
        # Not /api/onboarding: once onboarding is done, Home Assistant stops
        # serving it after a restart, and the HTTP cycle above restarts it.
        machine.wait_until_succeeds(
            "jq -e '.data.done | sort == [\"analytics\", \"core_config\", \"integration\", \"user\"]' "
            "/var/lib/hass/.storage/onboarding",
            timeout=60,
        )

    with subtest("declared entries exist, onboarding's are pruned"):
        # Home Assistant writes .storage on a short delay, hence waiting.
        # sun is created from default_config in configuration.yaml, so it is
        # kept; the rest were started by onboarding and are removed.
        machine.wait_until_succeeds(
            "jq -e '[.data.entries[] | select(.source != \"ignore\" and .source != \"system\") "
            "| .domain] | sort == [\"mqtt\", \"sun\"]' /var/lib/hass/.storage/core.config_entries",
            timeout=60,
        )

    with subtest("the options flow ran"):
        machine.wait_until_succeeds(
            "jq -e '.data.entries[] | select(.domain == \"mqtt\" and .options.discovery_prefix == \"discovered\")' "
            "/var/lib/hass/.storage/core.config_entries",
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

    with subtest("keepEntities disables the device's other entities"):
        machine.wait_until_succeeds(
            "jq -e '.data.entities[] | select(.unique_id == \"testdev_temperature\" and .disabled_by == \"user\")' "
            "/var/lib/hass/.storage/core.entity_registry",
            timeout=60,
        )
        machine.succeed(
            "jq -e '.data.entities[] | select(.entity_id == \"switch.lamp\" and .disabled_by == null)' "
            "/var/lib/hass/.storage/core.entity_registry"
        )

    with subtest("disableEntities disables exactly the matching entities"):
        machine.wait_until_succeeds(
            "jq -e '.data.entities[] | select(.unique_id == \"meter_humidity\" and .disabled_by == \"user\")' "
            "/var/lib/hass/.storage/core.entity_registry",
            timeout=60,
        )
        machine.succeed(
            "jq -e '.data.entities[] | select(.unique_id == \"meter_pressure\" and .disabled_by == null)' "
            "/var/lib/hass/.storage/core.entity_registry"
        )

    with subtest("a rename to a taken entity ID warns, and the run carries on"):
        out = machine.succeed("journalctl -u home-assistant-reconciler.service -o cat")
        assert "cannot rename sensor.meter_humidity to sensor.meter_pressure" in out, out
        machine.succeed(
            "jq -e '.data.entities[] | select(.unique_id == \"meter_pressure\" and .entity_id == \"sensor.meter_pressure\")' "
            "/var/lib/hass/.storage/core.entity_registry"
        )

    with subtest("a skipped rename keeps its entity enabled under keepEntities"):
        machine.wait_until_succeeds(
            "jq -e '.data.entities[] | select(.unique_id == \"gadget_level\" and .disabled_by == null)' "
            "/var/lib/hass/.storage/core.entity_registry",
            timeout=30,
        )

    with subtest("the owner's person follows exactly the declared trackers"):
        machine.wait_until_succeeds(
            "jq -e '.data.items[] | select(.name == \"Test Owner\") "
            "| .device_trackers == [\"device_tracker.test_phone\"]' "
            "/var/lib/hass/.storage/person",
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
        # Judged by the new run's own journal, so an earlier run's result
        # cannot pass for it.
        show = "systemctl show -p InvocationID --value home-assistant-reconciler.service"
        before = machine.succeed(show).strip()
        machine.succeed("systemctl restart home-assistant.service")
        machine.wait_until_succeeds(f'test "$({show})" != "{before}"', timeout=120)
        machine.wait_for_unit("home-assistant-reconciler.service", timeout=600)
        run = machine.succeed(show).strip()
        out = machine.succeed(f"journalctl _SYSTEMD_INVOCATION_ID={run} -o cat")
        assert "done: 0 changes" in out, out

    with subtest("a registered phone's entry is never pruned"):
        machine.succeed("register-test-phone")
        machine.wait_until_succeeds(
            "jq -e '.data.entries[] | select(.domain == \"mobile_app\")' "
            "/var/lib/hass/.storage/core.config_entries",
            timeout=60,
        )
        show = "systemctl show -p InvocationID --value home-assistant-reconciler.service"
        machine.succeed("systemctl restart home-assistant-reconciler.service")
        run = machine.succeed(show).strip()
        out = machine.succeed(f"journalctl _SYSTEMD_INVOCATION_ID={run} -o cat")
        assert "done:" in out, out
        assert "removed mobile_app" not in out, out
        machine.sleep(15)
        machine.succeed(
            "jq -e '.data.entries[] | select(.domain == \"mobile_app\")' "
            "/var/lib/hass/.storage/core.config_entries"
        )

    with subtest("a rule's entities come back when it goes, and nothing else does"):
        machine.succeed(
            "/run/booted-system/specialisation/unruled/bin/switch-to-configuration test"
        )
        machine.wait_for_unit("home-assistant-reconciler.service", timeout=600)
        machine.wait_until_succeeds(
            "jq -e '.data.entities[] | select(.unique_id == \"meter_humidity\" and .disabled_by == null)' "
            "/var/lib/hass/.storage/core.entity_registry",
            timeout=60,
        )
        # Disabled by keepEntities, not by the rule.
        machine.succeed(
            "jq -e '.data.entities[] | select(.unique_id == \"testdev_temperature\" and .disabled_by == \"user\")' "
            "/var/lib/hass/.storage/core.entity_registry"
        )

    with subtest("changed steps recreate the entry, and the names come back"):
        machine.succeed(
            "/run/booted-system/specialisation/rotated/bin/switch-to-configuration test"
        )
        machine.wait_for_unit("home-assistant-reconciler.service", timeout=600)
        out = machine.succeed("journalctl -u home-assistant-reconciler.service -o cat")
        assert "removed mqtt entry '127.0.0.1' (declaration changed)" in out, out
        last = [line for line in out.splitlines() if "done:" in line][-1]
        # The cover that is never created, and the two clashing renames.
        assert "3 warnings" in last, last
        machine.wait_until_succeeds(
            "jq -e '.data.entities[] | select(.entity_id == \"switch.lamp\" and .name == \"Lamp\")' "
            "/var/lib/hass/.storage/core.entity_registry",
            timeout=60,
        )
  '';
}
