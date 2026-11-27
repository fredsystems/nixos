# The MyQ custom integration (bvdcode), for the Chamberlain garage door
# opener, which is not linked into Alarm.com. MyQ was removed from Home
# Assistant core. No Python requirements of its own. Built as
# ../custom-component.nix describes.
{ callPackage, lib }:
callPackage ../custom-component.nix { } {
  pinFile = ./pin.json;
  domain = "myq";

  meta = {
    description = "Community-maintained MyQ integration for Home Assistant";
    homepage = "https://github.com/bvdcode/home-assistant-myq";
    license = lib.licenses.mit;
  };
}
