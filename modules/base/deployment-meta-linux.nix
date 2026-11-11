# modules/base/deployment-meta-linux.nix
#
# Linux-only half of modules/base/deployment-meta.nix: the systemd-specific
# assertion and unit that cannot be expressed on Darwin at all (nix-darwin
# has no `systemd` option, so even `lib.mkIf false { systemd = ...; }` fails
# evaluation -- the definition has to be structurally absent). Imported only
# by flake/lib/mk-system.nix; mk-darwin-system.nix does not import this file.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.deployment;
in
{
  # Every declared critical unit must actually exist on this node.
  #
  # A typo -- "adguard.service" for "adguardhome.service", say -- would
  # otherwise be silently inert: colmena-apply-drifted.sh would find no
  # unit-file path to compare, conclude nothing critical changed, and
  # switch the node live. That is a protection that reports itself as
  # working while protecting nothing, which is worse than not having it.
  #
  # Failing evaluation is the right severity because the manifest, CI and
  # the deploy script all evaluate these configurations, so a typo cannot
  # reach a deploy.
  # systemd.services.tailscale-address-drift is gated with lib.mkIf, not
  # lib.optionalAttrs, deliberately: the condition reads cfg.tailscaleAddress,
  # a config value. lib.optionalAttrs evaluates its condition eagerly while
  # this module's own `config` attrset is being enumerated (needed to find
  # out what keys it contributes), and evaluating cfg.tailscaleAddress at
  # that point re-enters the very config fixed point being computed --
  # infinite recursion, verified. lib.mkIf defers the condition until the
  # module system actually resolves this specific option path instead.
  config = {
    assertions = lib.mapAttrsToList (unit: _: {
      assertion = config.systemd.units ? ${unit};
      message = ''
        deployment.criticalUnits names "${unit}", which is not a unit on this host.
        Check the spelling and that the service defining it is actually enabled here.
      '';
    }) cfg.criticalUnits;

    # Detect a stale deployment.tailscaleAddress.
    #
    # The literal is baked into container port bindings and exporter listen
    # addresses at build time. If the node's real address changes, those
    # binds point at an address the host no longer holds: containers fail to
    # start and exporters fail to listen. Both are loud, but they are loud at
    # the wrong moment -- mid-deploy, with no indication of the cause.
    #
    # This compares the configured value against `tailscale ip -4` after
    # activation and logs a warning naming both. Deliberately a warning and
    # not a failure: a re-IP is exactly when deploys need to keep working so
    # the new value can be rolled out, and refusing to activate would leave
    # the host stuck on its old generation.
    systemd.services.tailscale-address-drift = lib.mkIf (cfg.tailscaleAddress != null) {
      description = "Warn if deployment.tailscaleAddress no longer matches the running Tailscale address";
      after = [ "tailscaled.service" ];
      wants = [ "tailscaled.service" ];
      wantedBy = [ "multi-user.target" ];

      # No RemainAfterExit. A successful oneshot that stays "active"
      # is not restarted by switch-to-configuration when its definition
      # is unchanged, so the check would only ever run at boot -- which
      # is precisely when it is least useful, since a re-IP typically
      # happens while the machine is up. Verified: the unit ran once at
      # boot and did not re-run across a later deploy.
      #
      # Letting it go inactive on success, plus the restartTriggers
      # below, makes every activation re-run it.
      serviceConfig = {
        Type = "oneshot";
      };

      # Re-run on every activation.
      #
      # `unitConfig.X-Restart-Triggers` is deliberately NOT derived from
      # config.system.build.toplevel -- that is the derivation this unit
      # is part of, and referencing it here is an evaluation cycle
      # ("infinite recursion", observed). system.configurationRevision is
      # also unavailable: this repo forbids putting the flake's git rev
      # into a closure, because it would change every host's store path
      # on every commit (see flake/lib/mk-system.nix).
      #
      # Instead the unit is simply allowed to go inactive on success,
      # and StartLimitIntervalSec=0 keeps repeated starts from being
      # rate-limited. switch-to-configuration starts inactive units that
      # are wantedBy an active target on every activation, which gives
      # the desired behaviour without a synthetic trigger.
      unitConfig.StartLimitIntervalSec = 0;

      script = ''
        set -uo pipefail

        configured=${lib.escapeShellArg cfg.tailscaleAddress}

        # tailscaled may still be coming up; this check is advisory, so a
        # transient failure to read the address is not worth failing on.
        actual="$(${pkgs.tailscale}/bin/tailscale ip -4 2>/dev/null | head -n1 || true)"

        if [ -z "$actual" ]; then
          echo "tailscale-address-drift: could not read the current Tailscale address; skipping check"
          exit 0
        fi

        if [ "$actual" != "$configured" ]; then
          echo "tailscale-address-drift: MISMATCH" >&2
          echo "  deployment.tailscaleAddress = $configured" >&2
          echo "  actual tailscale ip -4      = $actual" >&2
          echo "  Container port bindings and exporter listen addresses are" >&2
          echo "  built from the configured value and will fail to bind." >&2
          echo "  Fix: set deployment.tailscaleAddress = \"$actual\" for this host." >&2
        else
          echo "tailscale-address-drift: ok ($actual)"
        fi
      '';
    };
  };
}
