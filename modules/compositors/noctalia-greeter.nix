# modules/compositors/noctalia-greeter.nix
# Monitor keys are "Make Model Serial" descriptions, which noctalia-greeter
# accepts as stable output identifiers.
#
# Emits the `[output]` table of greeter.toml, for
# `services.displayManager.noctalia-greeter.settings.output`. Positions are
# shifted so the top-left monitor sits at 0,0, and each output gets its
# desktop scale and refresh rate so logging in does not trigger a modeset.
{ lib, monitors }:

let
  all = lib.attrValues monitors;
  minOf = f: if all == [ ] then 0 else lib.foldl' lib.min (f (lib.head all)) (map f all);
  minX = minOf (m: m.x);
  minY = minOf (m: m.y);
  perOutput = f: lib.concatStringsSep "; " (lib.mapAttrsToList (name: m: "${name}:${f m}") monitors);
in
{
  layout = perOutput (m: "${toString (m.x - minX)},${toString (m.y - minY)}");
  scales = perOutput (m: toString m.scale);
  refresh_rate = perOutput (m: toString m.refresh);
}
