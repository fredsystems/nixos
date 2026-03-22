{
  lib,
  config,
  user,
  extraUsers ? [ ],
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;
  cfg = config.desktop.environments.modules.fredbar;
  inherit (config.desktop.environments.common) waitForWayland;
in
{
  options.desktop.environments.modules.fredbar = {
    enable = lib.mkEnableOption "fredbar";
  };

  config = lib.mkIf cfg.enable {
    home-manager.users = lib.genAttrs allUsers (_: {
      services.swaync.enable = lib.mkForce false;

      programs.fredbar = {
        enable = true;
      };

      # Override the systemd unit settings from the fredbar module:
      #
      # ExecStartPre: Wait for the Wayland socket before starting AGS. Without
      # this, fredbar starts during login before whichever compositor (Hyprland,
      # Niri, etc.) has created its socket, fails immediately, and spins through
      # restart attempts until it hits the burst limit and stays dead. Using the
      # socket directly is compositor-agnostic and works regardless of which
      # compositors are installed on the system.
      #
      # KillMode=process: The default "mixed" kills everything in the cgroup
      # when the unit stops, including hyprshutdown which is spawned by AGS to
      # do a graceful Hyprland logout. "process" restricts killing to only the
      # main AGS process, letting hyprshutdown survive in its own session (via
      # setsid) long enough to finish closing all windows.
      systemd.user.services.fredbar = {
        Service = {
          ExecStartPre = lib.mkForce waitForWayland;
          KillMode = lib.mkForce "process";
        };
      };

      programs.fredcal = {
        enable = true;
        server = config.sops.secrets."email/icloud/caldav_server".path;
        password = config.sops.secrets."email/icloud/password".path;
        username = config.sops.secrets."email/icloud/address".path;
        port = 5090;
      };
    });
  };
}
