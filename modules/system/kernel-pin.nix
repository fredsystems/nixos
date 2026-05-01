# modules/system/kernel-pin.nix
#
# Pin the kernel on Linux server hosts to the LTS 6.12 line, sourced from a
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
  kernelPkgs = import kernelPkgsInput { inherit system; };
in
{
  config = lib.mkIf pinActive {
    boot.kernelPackages = lib.mkDefault kernelPkgs.linuxPackages_6_12;
  };
}
