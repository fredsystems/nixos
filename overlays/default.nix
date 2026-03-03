# Nixpkgs overlays applied to all systems.
#
# This file is a standard nixpkgs overlay (final: prev: { ... }) and is
# imported directly by flake/lib/mk-system.nix and
# flake/lib/mk-darwin-system.nix via nixpkgs.overlays.
#
# To add overlays, create a new file next to this one and merge it in here,
# e.g.:
#
#   final: prev:
#   (import ./my-overlay.nix final prev)
#   // (import ./another-overlay.nix final prev)
#
# Each overlay file should follow the standard nixpkgs overlay convention:
#
#   final: prev: {
#     somePackage = prev.somePackage.override { ... };
#   }

_: _: { }
