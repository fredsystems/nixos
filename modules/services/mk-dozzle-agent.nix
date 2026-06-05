# mkDozzleAgent: Generates an ADSB container definition for the Dozzle log viewer agent.
#
# Usage in a host configuration:
#
#   services.adsb.containers = [
#     (import ../../../modules/services/mk-dozzle-agent.nix { })
#     # ... other containers
#   ];
#
# With options:
#
#   (import ../../../modules/services/mk-dozzle-agent.nix {
#     port = "3939:7007";
#     environmentFiles = [ config.sops.secrets."docker/myhost.env".path ];
#   })
{
  port ? "7007:7007",
  environmentFiles ? [ ],
}:
{
  name = "dozzle-agent";
  image = "amir20/dozzle:v10.6.5@sha256:fa12525776bf665147d82bf031ff262ee89a0a12454122558a353ec38ada4aaf";
  exec = "agent";
  volumes = [
    "/var/run/docker.sock:/var/run/docker.sock:ro"
  ];
  ports = [ port ];
}
// (if environmentFiles != [ ] then { inherit environmentFiles; } else { })
