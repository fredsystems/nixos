# Home Assistant from nixos-unstable, on this stable-channel host.
#
# The owner needs fixes newer than the stable channel's Home Assistant
# (2026-11-26: a map tile fix from August). The module is swapped too, not
# just the package, because the two have diverged: from 2026.11 Home
# Assistant imports `http:` from YAML once and then ignores it, and stable's
# module always renders that section, which would leave a standing repair
# issue. The HTTP settings are the reconciler's job instead; see `http` in
# modules/services/home-assistant-reconciler.
#
# Everything Python-side comes from the same nixpkgs, so set custom
# components from `unstable` too (./home-assistant.nix does).
#
# Also imported by the reconciler's VM test (flake/dev/checks.nix), so it
# exercises the Home Assistant deployed here.
{
  config,
  inputs,
  lib,
  ...
}:
let
  unstable = import inputs.nixpkgs { inherit (config.nixpkgs.hostPlatform) system; };
in
{
  disabledModules = [ "services/home-automation/home-assistant.nix" ];
  imports = [ "${inputs.nixpkgs}/nixos/modules/services/home-automation/home-assistant.nix" ];

  options.services.home-assistant.unstablePkgs = lib.mkOption {
    type = lib.types.raw;
    readOnly = true;
    default = unstable;
    defaultText = lib.literalExpression "import inputs.nixpkgs { }";
    description = "The unstable package set Home Assistant and its custom components come from.";
  };

  config = {
    services.home-assistant.package = unstable.home-assistant.overrideAttrs (_: {
      # As the module's own default: the install check runs the whole test
      # suite.
      doInstallCheck = false;
    });

  };
}
