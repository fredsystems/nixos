# nvrhub's half of house mode (agent-docs/plans/PLAN_06_HOME_ASSISTANT.md,
# 6.17): if Home Assistant on corehub stops publishing its heartbeat, the
# indoor cameras are re-armed here, so a Home Assistant that died in
# home_awake cannot leave them quiet. corehub's half is
# hosts/linux/corehub/home-automation/house-mode.nix.
{ config, lib, ... }:
let
  # frigate.nix gives exactly the indoor cameras their own objects.track
  # (person, dog, cat). The same rule picks them on corehub.
  indoor = lib.attrNames (
    lib.filterAttrs (_: c: (c.objects or { }) ? track) config.services.frigate.settings.cameras
  );
in
{
  imports = [ ./house-watchdog ];

  services.house-watchdog = {
    enable = true;
    # corehub's broker, as Frigate reaches it.
    broker = config.services.frigate.settings.mqtt.host;
    user = "nvr-watchdog";
    passwordFile = config.sops.secrets."home-assistant/mqtt/nvr-watchdog".path;
    cameras = indoor;
  };

  sops.secrets."home-assistant/mqtt/nvr-watchdog" = { };
}
