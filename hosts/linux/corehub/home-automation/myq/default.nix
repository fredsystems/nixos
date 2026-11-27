# MyQ, for the garage door (owner, 2026-11-27; Plan 06, 6.22). The
# integration is packaged here (./package.nix).
#
# The entry is created by hand, once, in Settings > Devices & Services: MyQ
# sends a one-time code by email or SMS at sign-in, which the reconciler
# cannot answer. After that the integration keeps and refreshes OAuth
# tokens, and the entry lives in .storage and Home Assistant's backups.
# keepDomains stops the reconciler pruning it as undeclared.
{ config, ... }:
{
  services.home-assistant.customComponents = [
    (config.services.home-assistant.unstablePkgs.callPackage ./package.nix { })
  ];

  services.home-assistant-reconciler.keepDomains = [ "myq" ];
}
