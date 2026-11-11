_: {
  # home.stateVersion used to be set here from a `stateVersion` builder
  # argument. It is now set fleet-wide by flake/lib/mk-system.nix and
  # flake/lib/mk-darwin-system.nix via `home-manager.sharedModules`, which
  # applies to every Home Manager user on a host -- so this module no longer
  # needs to set it itself. Kept as an import target (see modules/base/home.nix
  # and hosts/linux/fredvps/nik-home.nix) in case it grows other
  # user-agnostic Home Manager baseline config again.
}
