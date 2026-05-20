# nix-index-timer.nix
#
# Linux-only sub-module: weekly nix-index database refresh per user.
# Imported conditionally from ./default.nix (skipped on Darwin where the
# `systemd` NixOS option tree does not exist on nix-darwin).
{
  pkgs,
  user,
  extraUsers ? [ ],
  lib,
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;
in
{
  systemd.services = lib.listToAttrs (
    map (u: {
      name = "nix-index-${u}";
      value = {
        description = "Update nix-index database for ${u}";
        serviceConfig = {
          Type = "oneshot";
          User = u;
          ExecStart = "${lib.getExe' pkgs.nix-index "nix-index"}";
          Nice = 19;
          IOSchedulingClass = "idle";
        };
      };
    }) allUsers
  );

  systemd.timers = lib.listToAttrs (
    map (u: {
      name = "nix-index-${u}";
      value = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "weekly";
          Persistent = true;
          RandomizedDelaySec = "4h";
        };
      };
    }) allUsers
  );
}
