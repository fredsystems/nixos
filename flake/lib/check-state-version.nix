# Shared stateVersion validator.
#
# WHY THIS EXISTS
#
# `stateVersion` has no default anywhere by design: it used to default to
# "24.11", so nine of twelve hosts inherited it silently and one edit to that
# default would have retroactively moved every one of them -- the opposite of
# what the option is for. Every host now states its own, and omitting it is a
# hard evaluation error.
#
# Omission is caught by the missing-argument / missing-attribute error. This
# catches the other half: a value that is a well-formed string but not a NixOS
# release, e.g. "25.5" instead of "25.05", or "2411". Those pass `types.str`
# and would otherwise reach a host as a real, wrong stateVersion.
#
# It lives here rather than inline because there are THREE construction paths
# -- mkSystem, mkDarwinSystem, and colmena's own specialArgs, which builds its
# node arguments independently of mkSystem. Colmena being a separate path is
# the same reason the fleet once reported `unmanaged` (see the versionSuffix
# note in flake/deployment/colmena.nix). A single validator means the three
# cannot drift into enforcing different contracts, which is exactly what
# happened when only mkSystem had the guard.
#
# Note the Darwin split: on NixOS this value feeds BOTH system.stateVersion
# and home-manager's home.stateVersion. On Darwin it feeds ONLY home-manager
# -- nix-darwin's own system.stateVersion is a small integer, set in
# profiles/darwin.nix. Both are YY.MM strings, so one validator covers them.
context: stateVersion:
if
  builtins.isString stateVersion && builtins.match "[0-9][0-9]\\.[0-9][0-9]" stateVersion != null
then
  stateVersion
else
  throw (
    "${context}: stateVersion is '${builtins.toString stateVersion}', which is not "
    + "a NixOS release of the form YY.MM (e.g. \"24.11\"). Fix it in "
    + "flake/hosts/servers.nix, flake/hosts/nixos.nix or flake/hosts/darwin.nix. "
    + "Do NOT change a host's stateVersion to make this pass -- it must keep the "
    + "value the machine was originally installed with, or the host silently "
    + "changes release-migration behaviour."
  )
