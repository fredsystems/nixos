# mkContainerSecret: declare a sops secret that is consumed as a container's
# --env-file, and wire it so the container restarts when the secret changes.
#
# THE BUG THIS EXISTS TO FIX
#
# A container's systemd unit is generated from its Nix definition, and its env
# file is referenced by a path (/run/secrets/docker/<host>/<name>.env) that
# stays the same across secret rotations. Editing a value inside secrets.yaml
# therefore produces a byte-identical unit: systemd sees no change, does not
# restart, and the container keeps running with the OLD environment until some
# unrelated change happens to restart it.
#
# That is a silent failure -- the deploy reports success while the running
# system does not match the configuration. Repointing sdrhub's ADS-B feed
# targets from a public IP to a Tailscale address is purely a secrets edit, so
# without this the feeds would have kept talking to the old address.
#
# WHY restartUnits AND NOT restartTriggers
#
# `restartTriggers` needs a value that changes with the secret's CONTENT. The
# only hash sops-nix exposes is `sopsFileHash`, which covers the entire sops
# file -- and every secret in this repo lives in one shared secrets.yaml. Using
# it would restart every container on the host whenever any unrelated secret
# changed.
#
# `restartUnits` is resolved at activation time by sops-install-secrets, which
# compares the decrypted bytes of the old and new secret (`bytes.Equal` in
# main.go). That gives exactly the semantics wanted:
#
#   (a) Restarts only when THAT secret's plaintext actually changed.
#       Re-deploying an unchanged secret restarts nothing.
#
#   (b) Never restarts on top of a restart that is already happening.
#       It is emitted as `try-restart`, and switch-to-configuration acts on
#       each unit once, so a container whose definition also changed restarts
#       exactly one time rather than twice. `try-restart` is also a no-op on a
#       unit that is not running, so first boot does not double-start.
#
# WHY THIS IS A HELPER RATHER THAN LOGIC IN adsb-docker-units.nix
#
# Deriving the mapping inside that module is impossible: host configs write
#
#   environmentFiles = [ config.sops.secrets."docker/x.env".path ];
#
# so `services.adsb.containers` already depends on `sops.secrets`. Defining
# `sops.secrets` from `cfg.containers` closes the loop and Nix aborts with
# "infinite recursion" (observed, not assumed). Declaring the relationship at
# the point the secret is defined has no cycle, because the container list is
# never consulted.
#
# USAGE
#
#   sops.secrets = {
#     "docker/sdrhub/ultrafeeder.env" = mkContainerSecret "ultrafeeder";
#
#     # Several containers sharing one secret:
#     "docker/sdrhub/shared.env" = mkContainerSecrets [ "a" "b" ];
#
#     # With extra settings:
#     "docker/sdrhub/other.env" = mkContainerSecret "other" // { mode = "0400"; };
#   };
{
  # Secret consumed by a single container. The argument is the container's
  # `name`, which is what adsb-docker-units.nix turns into docker-<name>.
  mkContainerSecret = containerName: {
    format = "yaml";
    restartUnits = [ "docker-${containerName}.service" ];
  };

  # Secret shared by several containers; all of them restart.
  mkContainerSecrets = containerNames: {
    format = "yaml";
    restartUnits = map (n: "docker-${n}.service") containerNames;
  };
}
