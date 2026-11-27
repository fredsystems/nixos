# The Alarm.com custom integration, ibasebcast's maintained fork, which
# vendors its Alarm.com client. Pinned by ./pin.json, which
# scripts/update-alarmdotcom.sh and .github/workflows/update-alarmdotcom.yaml
# keep current through reviewed PRs.
#
# Its Python requirements come from the nixpkgs Home Assistant is built from,
# never pip: the manifest check fails the build when one no longer satisfies
# manifest.json, and the install check imports every module, so a missing or
# renamed dependency fails here rather than on corehub.
{
  lib,
  fetchFromGitHub,
  buildHomeAssistantComponent,
  home-assistant,
}:
let
  pin = lib.importJSON ./pin.json;
  python = home-assistant.python3Packages;
in
buildHomeAssistantComponent {
  owner = "ibasebcast";
  domain = "alarmdotcom";
  inherit (pin) version;

  src = fetchFromGitHub {
    owner = "ibasebcast";
    repo = "ha-alarmdotcom";
    tag = "v${pin.version}";
    inherit (pin) hash;
  };

  dependencies = with python; [
    beautifulsoup4
    mashumaro
    phonenumbers
    pyhumps
    typer
  ];

  # FIXME(alarmdotcom-pyhumps-pin): WORKAROUND, not a fix. manifest.json asks
  # for pyhumps~=3.8.0 (3.8.x only); nixpkgs has 3.9.0, and the integration
  # only uses it to convert names between camelCase and snake_case. Delete
  # this once the manifest accepts 3.9. No upstream issue (owner's choice),
  # so it is not in .github/tracked-upstream-fixes.json: instead
  # .github/workflows/update-alarmdotcom.yaml builds each new release without
  # it and says in the bump PR whether it can go.
  ignoreVersionRequirement = [ "pyhumps" ];

  # Import every module with Home Assistant and the dependencies above, as
  # Home Assistant would when loading the integration. A hook, not
  # installCheckPhase: defining that switches off the manifest check.
  doInstallCheck = true;
  nativeInstallCheckInputs = [ python.homeassistant ];
  postInstallCheck = ''
    PYTHONPATH="$out:$PYTHONPATH" python3 - <<'EOF'
    import importlib
    import pkgutil

    import custom_components.alarmdotcom as integration

    modules = [integration.__name__] + [
        m.name
        for m in pkgutil.walk_packages(integration.__path__, integration.__name__ + ".")
    ]
    for name in modules:
        importlib.import_module(name)
    print(f"imported {len(modules)} modules")
    EOF
  '';

  meta = {
    description = "Alarm.com integration for Home Assistant, maintained fork";
    homepage = "https://github.com/ibasebcast/ha-alarmdotcom";
    license = with lib.licenses; [
      asl20
      mit
    ];
  };
}
