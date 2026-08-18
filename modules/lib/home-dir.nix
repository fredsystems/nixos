# Computes a user's home directory path for either platform.
#
# Pure function, imported directly by relative path rather than threaded
# through specialArgs — it is needed in a NixOS module (modules/secrets/sops.nix),
# a home-manager module for the primary user (modules/base/home-linux.nix), a
# home-manager module for a second, non-primary user
# (hosts/linux/fredvps/nik-home.nix), and a NixOS module that iterates over a
# list of users (features/common/git/default.nix). Those four call sites
# receive their module arguments differently enough (see the callers) that a
# plain importable function is the only thing genuinely reachable from all of
# them without widening specialArgs.
{
  username,
  isDarwin ? false,
}:
if isDarwin then "/Users/${username}" else "/home/${username}"
