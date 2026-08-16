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
#
# SECURITY: this container mounts the Docker socket, so anything that can
# reach its port can read the logs of every container on the host. Dozzle
# agents authenticate with a SHARED self-signed certificate that ships in the
# image -- it is not a per-deployment secret, so it does not distinguish your
# Dozzle instance from anyone else's. Upstream is explicit about the
# consequence: "if Dozzle is exposed externally and an attacker knows exactly
# which port the agent is running on, then they can set up their own Dozzle
# instance and connect to the agent."
#
# The default below therefore binds 0.0.0.0 only because Docker's `-p` has no
# other default. On a LAN-only host that is fine. On any host with a public
# interface, pass an explicit bind address -- see fredvps, which publishes on
# its Tailscale address after this port was found open to the internet.
{
  port ? "7007:7007",
  environmentFiles ? [ ],
}:
{
  name = "dozzle-agent";
  image = "amir20/dozzle:v10.7.2@sha256:01f9018ffdaa0ec523f9a91dea3eff65b25cdb5f0566ac6d5a2cb4cf591e35e9";
  exec = "agent";
  volumes = [
    "/var/run/docker.sock:/var/run/docker.sock:ro"
  ];
  ports = [ port ];
}
// (if environmentFiles != [ ] then { inherit environmentFiles; } else { })
