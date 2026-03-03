# Nixpkgs overlays applied to all systems.
#
# Add overlays here as additional files and import them below, e.g.:
#
#   imports = [ ./my-overlay.nix ];
#
# Each overlay file should be a standard nixpkgs overlay:
#
#   final: prev: {
#     somePackage = prev.somePackage.override { ... };
#   }
#
# This file is imported by lib/mk-system.nix and lib/mk-darwin-system.nix.

_: _: { }
