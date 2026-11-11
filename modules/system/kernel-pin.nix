# modules/system/kernel-pin.nix
#
# Pin the kernel on Linux server hosts to the LTS 6.18 line, sourced from a
# dedicated `nixpkgs-kernel` flake input rather than the host's normal pkgs
# tree.  This decouples kernel bumps (which require a reboot to take effect)
# from the weekly auto-merged nixpkgs-stable churn, so kernel updates land
# on their own monthly, manual-merge cadence via .github/workflows/update-flakes.yaml.
#
# Scope:
#   * Servers (deployment.role != "desktop"): pin applied.
#   * Desktops / laptops (deployment.role == "desktop"): no-op.  Daytona and
#     maranello keep their own boot.kernelPackages = pkgs.linuxPackages_latest.
#   * This module is only ever imported on Linux (modules/base/system-linux.nix);
#     it is never reached on Darwin.
#
# The pin uses lib.mkDefault so an individual server can still override
# (e.g. to test a newer kernel) by setting boot.kernelPackages explicitly.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  pinActive = config.deployment.role != "desktop";
in
{
  # pkgs.kernelPinPkgs is provided by an overlay in flake/lib/mk-system.nix,
  # which imports kernelPkgsInput once per host.  It is a separate evaluation
  # from the host's main pkgs tree but shares the cache.nixos.org binary cache
  # because it points at a real nixpkgs commit.
  #
  # The overlay threads the fleet's unfree predicate
  # (modules/base/nixpkgs-unfree.nix) through to that import, and that is not
  # merely defensive: a second, independent `import` of nixpkgs starts from an
  # empty config, and check-meta.nix defaults the predicate to `x: false` --
  # every unfree package reachable from `boot.kernelPackages` would otherwise
  # be refused no matter what the fleet allowlist says. That was invisible
  # until something actually pulled an unfree package out of the kernel tree:
  # nvrhub's NVIDIA driver needs `hardware.nvidia.package` from
  # `config.boot.kernelPackages.nvidiaPackages.*` so the kernel module is built
  # against the pinned 6.18 kernel, and that resolves nvidia-x11 against this
  # tree, not the host's main one.
  config = lib.mkIf pinActive {
    boot.kernelPackages = lib.mkDefault pkgs.kernelPinPkgs.linuxPackages_6_18;
  };
}
