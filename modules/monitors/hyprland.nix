# modules/monitors/renderers/hyprland.nix
{ lib, monitors }:

lib.mapAttrsToList (
  name: m:
  "${name}, ${
    if m.refresh >= 120 then
      "highrr"
    else
      "${toString m.width}x${toString m.height}@${toString m.refresh}"
  }, ${toString m.x}x${toString m.y}, ${toString m.scale}"
) monitors
