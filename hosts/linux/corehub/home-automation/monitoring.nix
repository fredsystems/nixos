# Home Assistant device health in Prometheus, for the alerts in
# modules/monitoring/master/alert-rules/home-automation-alerts.yaml: battery
# levels, the front door lock being jammed or unreachable, and the Alarm.com
# panel's trouble flags.
#
# Home Assistant's prometheus integration serves /api/prometheus. It is
# scraped over loopback by corehub's own Prometheus, so it needs no token
# (requires_auth = false). The nginx vhost refuses that path, so it is not
# readable through ha.int.fredsystems.org. Only the entities the alerts use
# are exported.
{ config, ... }:
let
  port = config.services.home-assistant-reconciler.port;
in
{
  services.home-assistant = {
    extraComponents = [ "prometheus" ];
    config.prometheus = {
      requires_auth = false;
      filter = {
        include_domains = [ "lock" ];
        include_entity_globs = [
          "sensor.*_battery_level"
          "binary_sensor.*_lock_jammed"
        ];
        # The companion app reports a phone's own battery as
        # sensor.<phone>_battery_level, which would page on every evening
        # below 25%. Phones are not house monitoring. Listed by entity ID: in
        # Home Assistant's filter a matching include glob beats an exclude
        # glob, and only exclude_entities beats it. A new phone goes here.
        exclude_entities = [ "sensor.iphone_battery_level" ];
        # The Alarm.com panel's trouble flags the alerts watch: low battery
        # (a sensor's or the panel's), panel not responding, AC power lost.
        include_entities = [
          "binary_sensor.home_sensor_low_battery"
          "binary_sensor.home_panel_low_battery"
          "binary_sensor.home_panel_not_responding"
          "binary_sensor.home_ac_failure"
        ];
      };
    };
  };

  services.prometheus.scrapeConfigs = [
    {
      job_name = "home-assistant";
      scrape_interval = "60s";
      metrics_path = "/api/prometheus";
      static_configs = [
        {
          targets = [ "127.0.0.1:${toString port}" ];
          labels = {
            hostname = "corehub";
            role = "master";
            exporter = "home-assistant";
          };
        }
      ];
    }
  ];
}
