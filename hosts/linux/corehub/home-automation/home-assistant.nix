# Home Assistant. Plan 06, 6.5, 6.19 and 6.20.
#
# Everything that matters is declared here, by the owner's requirement:
# configuration.yaml from `config`, and the parts Home Assistant keeps in
# .storage (onboarding, integrations, areas, device and entity names) through
# modules/services/home-assistant-reconciler. Nothing is set by hand in the
# UI. See "Home Assistant's configuration is declarative" in
# agent-docs/plans/PLAN_06_HOME_ASSISTANT.md for what that covers and the one
# gap (mobile_app entries come from the phone).
#
# Bound to loopback and reached only through the `ha` vhost in
# ../configuration.nix, like Grafana.
{ config, pkgs, ... }:
let
  hass = config.services.home-assistant;
  url = "https://ha.int.fredsystems.org";
in
{
  imports = [ ../../../../modules/services/home-assistant-reconciler ];

  services = {
    home-assistant = {
      enable = true;

      extraComponents = [
        "default_config"
        # Onboarding starts a met entry; the reconciler prunes it.
        "met"
        "mqtt"
        "zwave_js"
      ];

      customComponents = [ pkgs.home-assistant-custom-components.frigate ];

      config = {
        default_config = { };

        homeassistant = {
          name = "Home";
          # The house's location is not published in this repository. The
          # values come from sops through secrets.yaml, written at the end of
          # this file.
          latitude = "!secret home_latitude";
          longitude = "!secret home_longitude";
          elevation = "!secret home_elevation";
          unit_system = "us_customary";
          time_zone = config.time.timeZone;
          country = "US";
          currency = "USD";
          external_url = url;
          internal_url = url;
        };

        http = {
          server_host = [ "127.0.0.1" ];
          use_x_forwarded_for = true;
          trusted_proxies = [ "127.0.0.1" ];
        };
      };
    };

    home-assistant-reconciler = {
      enable = true;

      owner = {
        name = "Fred";
        username = "fred";
        passwordFile = config.sops.secrets."home-assistant/owner_password".path;
      };

      secrets = {
        mqtt-password = config.sops.secrets."home-assistant/mqtt/homeassistant".path;
        frigate-password = config.sops.secrets."home-assistant/frigate_password".path;
        frigate-rtsp-url = config.sops.templates."frigate-rtsp-url-template".path;
      };

      integrations = {
        mqtt.steps.broker = {
          broker = "127.0.0.1";
          port = 1883;
          username = "homeassistant";
          password._secret = "mqtt-password";
        };

        zwave_js.steps.manual.url = "ws://127.0.0.1:${toString config.services.zwave-js.port}";

        # Plan 06, 6.11. Over the TLS name, as the login nvrhub's
        # frigate-users.nix keeps for it; Frigate's unauthenticated
        # 127.0.0.1:5000 listener is never published. Camera state and
        # switches arrive over MQTT, which Frigate publishes to the broker
        # above.
        frigate.steps.user = {
          url = "https://nvr.int.fredsystems.org";
          validate_ssl = true;
          username = "homeassistant";
          password._secret = "frigate-password";
        };

        # Live video comes from nvrhub's go2rtc restream, which needs a login
        # from off-host. The integration renders this per camera, with
        # `name` the Frigate camera name. The rest are the flow's defaults,
        # stated because the options form submits every field.
        frigate.optionsFlow.init = {
          rtsp_url_template._secret = "frigate-rtsp-url";
          enable_webrtc = false;
          notification_proxy_enable = true;
          media_browser_enable = true;
          notification_proxy_expire_after_seconds = 0;
        };
      };

      # Onboarding's own entries (met, radio_browser, shopping_list,
      # google_translate) and its default areas go; only what is declared here
      # stays. Entries configuration.yaml creates, like sun, are kept.
      pruneIntegrations = true;
      pruneAreas = true;

      # 6.20. Daily at 02:30, database included, a week kept, in
      # /var/lib/hass/backups. Unencrypted: the NAS that pulls them holds
      # every other backup in the clear too, and a restore then needs no key
      # beyond what is already in sops.
      backup = {
        automatic_backups_configured = true;
        create_backup = {
          agent_ids = [ "backup.local" ];
          include_database = true;
          password = null;
        };
        agents."backup.local".protected = false;
        retention = {
          copies = 7;
          days = null;
        };
        schedule = {
          recurrence = "daily";
          time = "02:30:00";
        };
      };
    };

    # Source side only: proves the backups are being made, not that the NAS
    # pulled them. See modules/monitoring/agent/backup-freshness.nix.
    backupFreshness.artifacts.home-assistant = {
      path = "${hass.configDir}/backups";
      pattern = "*.tar";
      # Daily, so a healthy age peaks just over 24 h.
      maxAgeSeconds = 108000;
      # Seven kept; more means retention stopped working.
      maxCount = 9;
      description = "Home Assistant backups";
    };
  };

  sops = {
    # Home Assistant reads `!secret` values from secrets.yaml in its config
    # directory.
    templates."home-assistant-secrets.yaml" = {
      owner = "hass";
      path = "${hass.configDir}/secrets.yaml";
      restartUnits = [ "home-assistant.service" ];
      content = ''
        home_latitude: ${config.sops.placeholder."home-assistant/latitude"}
        home_longitude: ${config.sops.placeholder."home-assistant/longitude"}
        home_elevation: ${config.sops.placeholder."home-assistant/elevation"}
      '';
    };

    # A whole URL, because the reconciler substitutes a secret for a whole
    # value. Root-only; the reconciler reads it through LoadCredential=.
    templates."frigate-rtsp-url-template" = {
      content = "rtsp://homeassistant:${
        config.sops.placeholder."home-assistant/go2rtc_rtsp_password"
      }@nvr.int.fredsystems.org:8554/{{ name }}";
      restartUnits = [ "home-assistant-reconciler.service" ];
    };

    secrets = {
      "home-assistant/go2rtc_rtsp_password" = { };
      "home-assistant/latitude" = { };
      "home-assistant/longitude" = { };
      "home-assistant/elevation" = { };
      "home-assistant/owner_password".restartUnits = [ "home-assistant-reconciler.service" ];
      "home-assistant/frigate_password".restartUnits = [ "home-assistant-reconciler.service" ];
    };
  };
}
