{
  lib,
  ...
}:
{
  # Idle timings the shell applies inside a user session, kept here rather
  # than in the shell's own settings so other parts of the desktop can
  # follow the same schedule.
  options.desktop.environments.shell.idleTimeouts = {
    lock = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = "Seconds of inactivity before the session locks.";
    };
    screenOff = lib.mkOption {
      type = lib.types.ints.positive;
      default = 600;
      description = "Seconds of inactivity before the monitors turn off.";
    };
    suspend = lib.mkOption {
      type = lib.types.ints.positive;
      default = 900;
      description = "Seconds of inactivity before the machine suspends.";
    };
  };
}
