{
  lib,
  config,
  pkgs,
  ...
}:
let
  greeter = config.services.displayManager.noctalia-greeter;
  timeouts = config.desktop.environments.shell.idleTimeouts;

  # Seconds between checks. The suspend lands at most this long after the
  # session-equivalent time.
  pollInterval = 15;
  darkPollsBeforeSuspend = lib.max 1 ((timeouts.suspend - timeouts.screenOff) / pollInterval);

  # noctalia-greeter can blank its outputs after an idle timeout but never
  # suspends, and it does not report an idle hint to logind, so logind's
  # IdleAction never sees the greeter session as idle. This fills the gap:
  # once the greeter is the active session on seat0 and has blanked every
  # connected output, suspend after the same extra delay a user session
  # waits between screen-off and suspend.
  #
  # Darkness is read from DRM sysfs, where the greeter turning an output off
  # shows up as the connector being disabled. Polls are counted rather than
  # timestamped: they only run while the machine is awake, so time spent
  # suspended never counts towards the next suspend.
  watcher = pkgs.writeShellApplication {
    name = "greeter-idle-suspend";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      outputs_dark() {
        local connector connected=0
        for connector in /sys/class/drm/card*-*; do
          [ "$(cat "$connector/status" 2>/dev/null || true)" = connected ] || continue
          connected=1
          if [ "$(cat "$connector/enabled" 2>/dev/null || true)" = enabled ] \
            && [ "$(cat "$connector/dpms" 2>/dev/null || true)" = On ]; then
            return 1
          fi
        done
        [ "$connected" -eq 1 ]
      }

      greeter_active() {
        local session
        session="$(loginctl show-seat seat0 --property=ActiveSession --value 2>/dev/null || true)"
        [ -n "$session" ] || return 1
        [ "$(loginctl show-session "$session" --property=Class --value 2>/dev/null || true)" = greeter ]
      }

      dark_polls=0
      while true; do
        sleep ${toString pollInterval}
        if outputs_dark && greeter_active; then
          dark_polls=$((dark_polls + 1))
        else
          dark_polls=0
        fi
        if [ "$dark_polls" -ge ${toString darkPollsBeforeSuspend} ]; then
          dark_polls=0
          echo "greeter idle for ${toString timeouts.suspend}s, suspending"
          systemctl suspend || true
        fi
      done
    '';
  };
in
{
  config = lib.mkIf greeter.enable {
    assertions = [
      {
        assertion = timeouts.suspend > timeouts.screenOff;
        message = "desktop.environments.shell.idleTimeouts: suspend must come after screenOff; the greeter only suspends once its outputs are off.";
      }
    ];

    services.displayManager.noctalia-greeter.settings.idle.timeout = timeouts.screenOff;

    systemd.services.greeter-idle-suspend = {
      description = "Suspend after the login screen has been idle";
      wantedBy = [ "greetd.service" ];
      partOf = [ "greetd.service" ];
      after = [ "greetd.service" ];
      serviceConfig = {
        ExecStart = lib.getExe watcher;
        Restart = "always";
        RestartSec = "5s";
      };
    };
  };
}
