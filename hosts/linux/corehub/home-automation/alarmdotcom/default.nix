# Alarm.com (owner, 2026-11-27). The integration is packaged here
# (./package.nix), from the same nixpkgs as Home Assistant.
#
# The entry is created by hand, once, in Settings > Devices & Services:
# Alarm.com asks for a one-time code at login, which the reconciler cannot
# answer. After that the integration keeps a trusted-device token, and the
# entry lives in .storage and Home Assistant's backups. keepDomains stops the
# reconciler pruning it as undeclared.
{ config, ... }:
{
  services.home-assistant.customComponents = [
    (config.services.home-assistant.unstablePkgs.callPackage ./package.nix { })
  ];

  services.home-assistant-reconciler.keepDomains = [ "alarmdotcom" ];
}
