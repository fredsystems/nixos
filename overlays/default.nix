# Nixpkgs overlays applied to all systems.
#
# This file is a standard nixpkgs overlay (final: prev: { ... }) and is
# imported directly by flake/lib/mk-system.nix and
# flake/lib/mk-darwin-system.nix via nixpkgs.overlays.
#
# To add overlays, create a new file next to this one and add it here as
# a callPackage entry, e.g.:
#
#   my-package = final.callPackage ./my-package.nix { };
#
# Each standalone overlay file should follow the callPackage convention:
#
#   { someDep, anotherDep, ... }:
#   derivation ...

final: _: {
  cider3 = final.callPackage ./cider.nix { };
}
