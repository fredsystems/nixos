# modules/compositors/hyprland.nix
# Monitor keys are "Make Model Serial" descriptions; prefix with desc: for Hyprland.
#
# Emits a list of `hl.monitor({...})` Lua statement strings, suitable for
# splicing into `wayland.windowManager.hyprland.extraConfig` (under
# configType = "lua").
{ lib, monitors }:

let
  mkMode =
    m:
    if m.refresh >= 120 then
      "highrr"
    else
      "${toString m.width}x${toString m.height}@${toString m.refresh}";
in
lib.mapAttrsToList (
  name: m:
  ''hl.monitor({ output = "desc:${name}", mode = "${mkMode m}", position = "${toString m.x}x${toString m.y}", scale = ${toString m.scale} })''
) monitors
