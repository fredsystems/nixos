{
  lib,
  ...
}:
{
  # One idle policy for the whole seat. The shell applies it inside a user
  # session, and ../greeter-idle.nix applies the same screen-off and suspend
  # times at the login screen, so a machine left at the greeter (after a
  # reboot or a logout) sleeps exactly like one left logged in.
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
