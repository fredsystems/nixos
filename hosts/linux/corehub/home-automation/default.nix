# The house's automation hub. agent-docs/plans/PLAN_06_HOME_ASSISTANT.md.
{
  imports = [
    ./unstable.nix
    ./mosquitto.nix
    ./zwave-js.nix
    ./home-assistant.nix
    ./devices.nix
    ./homekit.nix
    ./automations.nix
    ./house-mode.nix
    ./dashboard.nix
    ./cameras.nix
    ./monitoring.nix
  ];
}
