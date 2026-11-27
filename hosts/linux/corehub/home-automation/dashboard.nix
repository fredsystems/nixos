# The House dashboard (owner, 2026-11-27; Plan 06, 6.13): the house mode,
# whether Fred is home, and buttons for Good Night and Good Morning. A YAML
# dashboard from the store, so it is declared here and read-only in the UI.
# The default Overview dashboard is left as Home Assistant makes it.
{ pkgs, ... }:
let
  script = name: label: icon: {
    type = "button";
    entity = "script.${name}";
    name = label;
    inherit icon;
    show_state = false;
    # Asks first: a stray tap on Good Morning disarms the house.
    tap_action = {
      action = "perform-action";
      perform_action = "script.${name}";
      confirmation.text = "Run ${label}?";
    };
  };

  dashboard = (pkgs.formats.yaml { }).generate "house-dashboard.yaml" {
    title = "House";
    views = [
      {
        title = "House";
        path = "house";
        cards = [
          {
            type = "entities";
            title = "House mode";
            entities = [
              {
                entity = "input_select.house_mode";
                name = "Mode";
              }
              {
                entity = "person.fred";
                name = "Fred";
              }
              {
                entity = "timer.house_awake_expiry";
                name = "Re-arms by itself in";
              }
            ];
          }
          {
            type = "grid";
            columns = 2;
            square = false;
            cards = [
              (script "good_night" "Good Night" "mdi:weather-night")
              (script "good_morning" "Good Morning" "mdi:weather-sunny")
            ];
          }
        ];
      }
    ];
  };
in
{
  services.home-assistant.config.lovelace.dashboards.house-mode = {
    mode = "yaml";
    title = "House";
    icon = "mdi:home-account";
    show_in_sidebar = true;
    filename = toString dashboard;
  };
}
