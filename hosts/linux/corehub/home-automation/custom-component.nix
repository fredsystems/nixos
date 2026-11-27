# How corehub packages a Home Assistant custom integration that nixpkgs does
# not carry (./alarmdotcom, ./myq): pinned by its pin.json (repo, version,
# hash), which scripts/update-ha-component.sh and
# .github/workflows/update-ha-components.yaml keep current through reviewed
# PRs.
#
# Its Python requirements come from the nixpkgs Home Assistant is built from,
# never pip. The manifest check fails the build when one no longer satisfies
# manifest.json, and the install check imports every module, so a missing or
# renamed dependency fails here rather than on corehub.
{
  lib,
  fetchFromGitHub,
  buildHomeAssistantComponent,
  home-assistant,
}:
{
  pinFile,
  domain,
  dependencies ? [ ],
  ignoreVersionRequirement ? [ ],
  meta,
}:
let
  pin = lib.importJSON pinFile;
  owner = lib.head (lib.splitString "/" pin.repo);
  repo = lib.last (lib.splitString "/" pin.repo);
in
buildHomeAssistantComponent {
  inherit
    owner
    domain
    dependencies
    ignoreVersionRequirement
    meta
    ;
  inherit (pin) version;

  src = fetchFromGitHub {
    inherit owner repo;
    tag = "v${pin.version}";
    inherit (pin) hash;
  };

  # Import every module with Home Assistant and the dependencies, as Home
  # Assistant would when loading the integration. A hook, not
  # installCheckPhase: defining that switches off the manifest check.
  doInstallCheck = true;
  nativeInstallCheckInputs = [ home-assistant.python3Packages.homeassistant ];
  postInstallCheck = ''
    PYTHONPATH="$out:$PYTHONPATH" python3 - <<'EOF'
    import importlib
    import pkgutil

    import custom_components.${domain} as integration

    modules = [integration.__name__] + [
        m.name
        for m in pkgutil.walk_packages(integration.__path__, integration.__name__ + ".")
    ]
    for name in modules:
        importlib.import_module(name)
    print(f"imported {len(modules)} modules")
    EOF
  '';
}
