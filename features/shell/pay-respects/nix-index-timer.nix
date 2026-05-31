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
          # nix-index invokes `nix-env -f <nixpkgs> -qaP` which needs a
          # nixpkgs path. systemd services run with no NIX_PATH, so we pin
          # nixpkgs to the flake input via -f.
          ExecStart = "${lib.getExe' pkgs.nix-index "nix-index"} -f ${pkgs.path}";
          Nice = 19;
          IOSchedulingClass = "idle";

          # nix-index streams every store path in nixpkgs and indexes their
          # file lists in memory. On small/headless hosts this can balloon
          # past 1.5 GB and, without swap, drive the box into hard reclaim
          # thrash that takes SSH down. Constrain the unit so a runaway
          # invocation dies cleanly via cgroup-level OOM instead of taking
          # the whole machine with it.
          MemoryHigh = "1200M";
          MemoryMax = "1800M";
          # If the kernel-wide OOM killer ever has to choose, pick this.
          OOMScoreAdjust = 1000;
          # Keep the timer alive even if the service is OOM-killed.
          OOMPolicy = "continue";
          # Don't let it dominate the CPU on a busy box either.
          CPUWeight = 20;
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
