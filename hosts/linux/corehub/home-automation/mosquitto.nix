# MQTT broker for Home Assistant and Frigate. Plan 06, 6.3.
#
# One listener, LAN-reachable because Frigate and the review watchdog run on
# nvrhub. Every client has its own user and password (sops), and anonymous
# access is off, so a client can only touch its own topics:
#
#   homeassistant  everything: Frigate's topics, discovery, and house/#
#   frigate        frigate/#, which is all Frigate publishes and reads
#   nvr-watchdog   reads house/#, where Home Assistant publishes its
#                  heartbeat (6.17)
#
# Plaintext on the wire, as the plan decided: the passwords cross the LAN
# unencrypted, between corehub and nvrhub only.
{ config, lib, ... }:
let
  users = {
    homeassistant = [ "readwrite #" ];
    frigate = [ "readwrite frigate/#" ];
    nvr-watchdog = [ "read house/#" ];
  };

  secret = user: "home-assistant/mqtt/${user}";
in
{
  services.mosquitto = {
    enable = true;
    listeners = [
      {
        port = 1883;
        settings.allow_anonymous = false;
        users = lib.mapAttrs (user: acl: {
          inherit acl;
          passwordFile = config.sops.secrets.${secret user}.path;
        }) users;
      }
    ];
  };

  networking.firewall.allowedTCPPorts = [ 1883 ];

  sops.secrets = lib.mapAttrs' (
    user: _:
    lib.nameValuePair (secret user) {
      restartUnits = [
        "mosquitto.service"
      ]
      # Home Assistant's own password is also an mqtt config-flow answer.
      ++ lib.optional (user == "homeassistant") "home-assistant-reconciler.service";
    }
  ) users;
}
