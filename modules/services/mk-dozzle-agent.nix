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
  image = "amir20/dozzle:v10.6.11@sha256:bc1ee4ba8d66c7fc0d03823a78486165fb219809f79eaf54cecf3114d647ab14";
  exec = "agent";
  volumes = [
    "/var/run/docker.sock:/var/run/docker.sock:ro"
  ];
  ports = [ port ];
}
// (if environmentFiles != [ ] then { inherit environmentFiles; } else { })
