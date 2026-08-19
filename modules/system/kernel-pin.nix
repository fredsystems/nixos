# modules/system/kernel-pin.nix
#
# Pin the kernel on Linux server hosts to the LTS 6.18 line, sourced from a
# dedicated `nixpkgs-kernel` flake input rather than the host's normal pkgs
# tree.  This decouples kernel bumps (which require a reboot to take effect)
# from the weekly auto-merged nixpkgs-stable churn, so kernel updates land
# on their own monthly, manual-merge cadence via .github/workflows/update-flakes.yaml.
#
# Scope:
#   * Servers (isDesktop = false, isDarwin = false): pin applied.
#   * Desktops / laptops (isDesktop = true): no-op.  Daytona and maranello
#     keep their own boot.kernelPackages = pkgs.linuxPackages_latest.
#   * Darwin (isDarwin = true): no-op.
#
# The pin uses lib.mkDefault so an individual server can still override
# (e.g. to test a newer kernel) by setting boot.kernelPackages explicitly.
{
  config,
  lib,
  kernelPkgsInput,
  system,
  isDesktop ? false,
  isDarwin ? false,
  ...
}:
let
  pinActive = !isDesktop && !isDarwin;

  # Import the kernel-pin nixpkgs once per host.  We only need the kernel
  # attributes; this is a separate evaluation from the host's main pkgs
  # tree but shares the cache.nixos.org binary cache because it points at
  # a real nixpkgs commit.
  #
  # The unfree predicate MUST be threaded through here, and is not merely
  # defensive.  modules/base/nixpkgs-unfree.nix calls itself the single source
  # of truth for the fleet, but it sets `nixpkgs.config.allowUnfreePredicate`,
  # which only ever applies to the host's MAIN pkgs tree.  This is a second,
  # independent `import` of nixpkgs, so it starts from an empty config and
  # check-meta.nix defaults the predicate to `x: false` -- every unfree package
  # reachable from `boot.kernelPackages` is refused no matter what the fleet
  # allowlist says.
  #
  # That is invisible until something actually pulls an unfree package out of
  # the kernel tree.  The first such case is nvrhub's NVIDIA driver:
  # `hardware.nvidia.package` has to come from
  # `config.boot.kernelPackages.nvidiaPackages.*` so the kernel module is built
  # against the pinned 6.18 kernel rather than some other tree's kernel, and
  # that resolves nvidia-x11 HERE.  Without this the eval fails with
  # nixpkgs' unfree error naming a package that is already on the allowlist,
  # which is a genuinely confusing way to discover the split.
  #
  # Deliberately the same expression as nixpkgs-unfree.nix:79-80 so the two
  # trees agree by construction.  No cycle: `nixpkgsUnfree.allowed` is a plain
  # list contributed by modules and nothing in it depends on
  # `boot.kernelPackages`.
  kernelPkgs = import kernelPkgsInput {
    inherit system;
    config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) config.nixpkgsUnfree.allowed;
  };
in
{
  config = lib.mkIf pinActive {
    boot.kernelPackages = lib.mkDefault kernelPkgs.linuxPackages_6_18;
  };
}
