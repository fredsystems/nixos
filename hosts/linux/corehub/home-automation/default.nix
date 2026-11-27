# The house's automation hub. agent-docs/plans/PLAN_06_HOME_ASSISTANT.md.
{
  imports = [
    ./mosquitto.nix
    ./zwave-js.nix
    ./home-assistant.nix
    ./devices.nix
  ];
}
