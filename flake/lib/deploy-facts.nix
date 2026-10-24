# deploy-facts.nix -- the evaluated half of "can this node take a live switch?"
#
# scripts/lib/deploy-guard.sh compares what a node is RUNNING against what the
# target closure WOULD install. This file is the second half: everything the
# guard needs to know about the target, as plain store paths and strings, so
# the shell side never has to know Nix option paths.
#
# Both deploy paths evaluate exactly this function:
#
#   scripts/colmena-apply-drifted.sh   nix eval .#lib.deployFacts.colmena
#   scripts/switch-preflight.sh        nix eval .#lib.deployFacts.nixos.<host>
#
# which is what stops the desktop and server guards from drifting apart -- the
# same reason scripts/check-colmena-parity.sh exists for the closures
# themselves. Adding a guard input means adding a field HERE, and both scripts
# get it.
#
# Shape, per node:
#
#   toplevel    system.build.toplevel                         drift test
#   systemd     systemd.package                               PID 1 re-exec
#   kernel      { image, modules }                            reboot owed
#   critical    { <unit> = { reason, path }; }                unit restart
#   processes   { <label> = { reason, pnames, path, name }; } session version
#
# `kernel.image` / `kernel.modules` are built from the same expressions
# nixos/modules/system/boot/kernel.nix builds the toplevel's `kernel` and
# `kernel-modules` from. `modules` is the SET of module packages (sorted,
# space-joined) rather than the kernel-modules tree's own path: the tree is a
# buildEnv + depmod wrapper whose hash moves on a mass rebuild while every
# .ko inside stays byte-identical.
#
# `critical.<unit>.path` indexes systemd.units.<unit> directly. That is safe
# because modules/base/deployment-meta.nix asserts every declared unit exists,
# so a typo fails evaluation instead of producing an empty path here -- which
# would read as "nothing critical changed".
{ lib }:
let
  of = n: {
    toplevel = n.config.system.build.toplevel.outPath;
    systemd = n.config.systemd.package.outPath;

    kernel = {
      image = "${n.config.boot.kernelPackages.kernel}/${n.config.system.boot.loader.kernelFile}";
      modules = lib.concatStringsSep " " (
        builtins.sort builtins.lessThan (
          map (p: p.outPath) (
            [ (lib.getOutput "modules" n.config.boot.kernelPackages.kernel) ]
            ++ n.config.boot.extraModulePackages
          )
        )
      );
    };

    critical = lib.mapAttrs (unit: reason: {
      inherit reason;
      path = n.config.systemd.units.${unit}.unit.outPath;
    }) n.config.deployment.criticalUnits;

    # `name` is the derivation name (pname-version); the guard splits it the
    # way builtins.parseDrvName does and compares the version half. See
    # deployment.criticalProcesses for why a same-version rebuild is reported
    # but not held. `pnames` is space-joined for the shell side.
    processes = lib.mapAttrs (_: p: {
      inherit (p) reason;
      pnames = lib.concatStringsSep " " p.pnames;
      path = p.package.outPath;
      inherit (p.package) name;
    }) n.config.deployment.criticalProcesses;
  };
in
{
  inherit of;
  forNodes = lib.mapAttrs (_: of);
}
