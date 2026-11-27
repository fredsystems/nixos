# The Alarm.com custom integration, ibasebcast's maintained fork, which
# vendors its Alarm.com client. Built as ../custom-component.nix describes.
{
  callPackage,
  home-assistant,
  lib,
}:
callPackage ../custom-component.nix { } {
  pinFile = ./pin.json;
  domain = "alarmdotcom";

  dependencies = with home-assistant.python3Packages; [
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
  # .github/workflows/update-ha-components.yaml builds each new release
  # without it and says in the bump PR whether it can go.
  ignoreVersionRequirement = [ "pyhumps" ];

  meta = {
    description = "Alarm.com integration for Home Assistant, maintained fork";
    homepage = "https://github.com/ibasebcast/ha-alarmdotcom";
    license = with lib.licenses; [
      asl20
      mit
    ];
  };
}
