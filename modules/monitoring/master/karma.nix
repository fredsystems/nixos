# modules/monitoring/master/karma.nix
#
# Karma: an alert dashboard for Alertmanager.
#
# WHY
#
# Pushover is a feed of events. It tells you what happened, in order, and is
# useless for answering "what is wrong right now" or "what did I already
# acknowledge". Karma provides current state instead: alerts grouped by
# label, with silence management.
#
# EXPOSURE
#
# Bound to 127.0.0.1 and reached through the existing nginx reverse proxy, so
# it is available on the LAN as http://karma.sdrhub.lan/ without opening a
# port of its own. No `openFirewall`.
#
# This matters more than for a read-only dashboard: Karma creates and expires
# silences, which makes it a control plane. Anyone who reaches the UI can
# silence every alert in the fleet, and the result is indistinguishable from a
# healthy quiet fleet. Keeping it behind nginx on the LAN, rather than exposed
# or published to the internet, is deliberate. If it is ever published, it
# needs auth in front of it (Karma has `authentication.basicAuth`, and
# `authorization.acl` for silences) or the Alertmanager entry set to
# `readonly = true`.
#
# The listen port is read back by the nginx vhost in
# hosts/linux/sdrhub/configuration.nix via
# config.services.karma.settings.listen.port, so the proxy target cannot drift
# out of sync with the service.
{
  services.karma = {
    enable = true;

    settings = {
      listen = {
        address = "127.0.0.1";
        # Upstream default is 8080, which ultrafeeder already publishes here.
        # 8090 is unused: sdrhub's containers occupy 8080-8087, and nothing
        # else in the repo references it.
        port = 8090;
      };

      alertmanager = {
        # Alertmanager's own evaluation is 15s; polling faster than that just
        # adds load without surfacing anything sooner.
        interval = "30s";

        servers = [
          {
            name = "sdrhub";
            uri = "http://127.0.0.1:9093";
            timeout = "10s";
          }
        ];
      };

      # The Watchdog deadman fires permanently by design, so without this it
      # would sit at the top of the UI forever and train the eye to ignore a
      # non-empty dashboard. The filter is a default, not a restriction --
      # clearing it in the UI still shows the Watchdog, which is occasionally
      # what you want when checking the alerting pipeline itself.
      filters.default = [ "alertname!=Watchdog" ];

      ui = {
        refresh = "30s";
        hideFiltersWhenIdle = true;
        colorTitlebar = true;
        theme = "dark";
        minimalGroupWidth = 420;
        alertsPerGroup = 5;
        collapseGroups = "collapsedOnMobile";
      };
    };
  };
}
