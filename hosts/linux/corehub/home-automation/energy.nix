# The Sense energy monitor (owner, 2026-11-27). Sense is cloud-only: Home
# Assistant polls the Sense account, not the monitor on the LAN. The
# reconciler creates the entry from the account's email and password, both
# in sops so the address stays out of this repository too. The account has no
# two-factor authentication; if it gains it, the flow's `validation` step
# asks for a code and the reconciler fails the run saying so.
{ config, ... }:
let
  reconciler = [ "home-assistant-reconciler.service" ];
in
{
  services.home-assistant.extraComponents = [ "sense" ];

  services.home-assistant-reconciler = {
    secrets = {
      sense-email = config.sops.secrets."home-assistant/sense/email".path;
      sense-password = config.sops.secrets."home-assistant/sense/password".path;
    };

    integrations.sense.steps.user = {
      email._secret = "sense-email";
      password._secret = "sense-password";
    };
  };

  sops.secrets = {
    "home-assistant/sense/email".restartUnits = reconciler;
    "home-assistant/sense/password".restartUnits = reconciler;
  };
}
