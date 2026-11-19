{
  pkgs,
  config,
  lib,
  ...
}:
let
  allUsers = config.shared.allUsers;
  repair = pkgs.writers.writePython3Bin "autotrash-repair" { } (
    builtins.readFile ./repair-trashinfo.py
  );
in
{
  config = {
    environment.systemPackages = [
      pkgs.autotrash
      pkgs.gtrash
    ];

    home-manager.users = lib.genAttrs allUsers (_: {
      systemd.user = {
        services = {
          autotrash = {
            Unit = {
              Description = "Empty Trash";
            };
            Service = {
              Type = "oneshot";
              # One unreadable .trashinfo (or a missing info/ directory)
              # makes autotrash abort without deleting anything.
              ExecStartPre = "${repair}/bin/autotrash-repair";
              ExecStart = "${pkgs.autotrash}/bin/autotrash --days 10";
            };
          };
        };

        timers = {
          autotrash = {
            Unit.Description = "Empty Trash";
            Timer = {
              Unit = "autotrash.service";
              Persistent = true;
              OnCalendar = "06:00";
            };
            Install.WantedBy = [ "timers.target" ];
          };
        };
      };
    });
  };
}
