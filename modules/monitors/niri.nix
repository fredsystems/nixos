# modules/monitors/renderers/niri.nix
{ monitors }:

builtins.mapAttrs (_: m: {
  inherit (m) scale;
  mode = {
    inherit (m) width height refresh;
  };
  position = {
    inherit (m) x y;
  };
}) monitors
