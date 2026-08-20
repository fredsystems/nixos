{
  config,
  ...
}:
{
  imports = [
    ../../../profiles/darwin.nix
    ../../../modules/services/github-runners.nix

    # Imported here rather than in profiles/darwin.nix because this is the
    # only Mac on the desk maranello sits at. Freds-MacBook-Pro is portable
    # and has no fixed edge to be reached across.
    ../../../features/desktop/lan-mouse
  ];

  # Receiving end only: this machine accepts input forwarded from maranello
  # and lists no clients of its own, so nothing here decides where a screen
  # edge is -- maranello's `position = "right"` does.
  #
  # TWO MANUAL STEPS, both one-time, neither expressible in Nix:
  #
  #  1. Grant Accessibility (for replaying input) and Input Monitoring (for
  #     the return-trip barrier -- an incoming connection creates an
  #     EnterOnly CGEventTap, src/service.rs) in System Settings -> Privacy &
  #     Security. macOS requires a human for anything that synthesises or
  #     observes input, by design. Until Accessibility is granted the daemon
  #     connects but emulates nothing, which presents as "the pointer crosses
  #     over but clicks do nothing".
  #
  #     Do this by running `lan-mouse` (no arguments) once, NOT by waiting for
  #     the launchd agent to ask. It never will: every permission-requesting
  #     call -- AXIsProcessTrustedWithOptions, CGRequestPostEventAccess,
  #     CGRequestListenEventAccess -- lives in the GTK crate
  #     (lan-mouse-gtk/src/macos_privacy.rs), while the daemon path only
  #     *checks* with AXIsProcessTrusted / CGPreflightPostEventAccess. A
  #     headless daemon therefore neither prompts nor gets listed in the
  #     Privacy panes at all. The GUI is present in this build because `gtk`
  #     is a default cargo feature.
  #
  #     THE TRAP, hit for real on first setup: granting the permission is not
  #     enough, and running the GUI does NOT apply it. The agent is already
  #     running, so the GUI logs "service already running!" (src/main.rs
  #     swallows IpcListenerCreationError::AlreadyRunning) and attaches to the
  #     existing daemon over IPC instead of starting its own. That daemon
  #     checked its permissions once at startup and never rechecks, so it goes
  #     on emulating nothing while the GUI cheerfully reports the permission
  #     as granted -- it looks like it worked, and it did not.
  #
  #     The daemon process itself has to be replaced. Cleanest:
  #
  #       launchctl kickstart -k gui/$UID/org.nix-community.home.lan-mouse
  #
  #     `pkill lan-mouse` also works (KeepAlive brings it straight back), as
  #     does a reboot. The grant carries across the restart because the GUI
  #     and the daemon are the same store path, and TCC keys on the
  #     executable rather than on the process.
  #
  #  2. Fill in `authorizedFingerprints` below. Being the listening side, this
  #     is the machine that decides who may connect, and an empty list refuses
  #     maranello. maranello's fingerprint does not exist until it has run
  #     lan-mouse once; read it there with the openssl command documented on
  #     the option, then record it here. It is not a secret -- it is the hash
  #     of a public certificate -- so it belongs in git, not in sops.
  desktop.lan-mouse = {
    enable = true;
    authorizedFingerprints = {
      "82:8e:f9:85:c4:b8:60:dc:70:a5:4f:f6:33:c5:cf:c3:6a:28:c5:77:5b:c0:d0:ba:b6:3b:0f:73:ce:fd:14:a4" =
        "maranello";
    };
  };

  sops.secrets."github-token" = { };

  ci.githubRunners = {
    enable = true;
    repo = "FredSystems/nixos";
    defaultTokenFile = config.sops.secrets."github-token".path;
    runnerCount = 4;
  };
}
