# modules/monitors/renderers/niri.nix
{ monitors }:

builtins.mapAttrs (_: m: {
  inherit (m) scale;
  mode = {
    inherit (m) width;
    inherit (m) height;
    inherit (m) refresh;
  };
  position = {
    inherit (m) x;
    inherit (m) y;
  };
}) monitors
