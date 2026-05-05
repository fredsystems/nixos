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
  image = "amir20/dozzle:v10.5.1@sha256:2f8d5c2b6181533a58246313b1d840a69ae04e6c1010e2f6bb52c2228342b443";
  exec = "agent";
  volumes = [
    "/var/run/docker.sock:/var/run/docker.sock:ro"
  ];
  ports = [ port ];
}
// (if environmentFiles != [ ] then { inherit environmentFiles; } else { })
