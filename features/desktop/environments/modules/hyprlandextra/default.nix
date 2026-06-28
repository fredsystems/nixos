{
  lib,
  pkgs,
  config,
  user,
  extraUsers ? [ ],
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;
  cfg = config.desktop.environments.modules.hyprlandextra;
in
{
  options.desktop.environments.modules.hyprlandextra = {
    enable = lib.mkEnableOption "extra Hyprland features";
  };

  config = lib.mkIf cfg.enable {
    home-manager.users = lib.genAttrs allUsers (_: {
      # Idle inhibition is now handled by wayle's built-in inhibitor
      # (`wayle idle toggle --indefinite`, bound in the Hyprland keybinds and
      # surfaced by the bar's idle-inhibit module), so the previous
      # systemd-inhibit "caffeine" service is no longer needed.
      home.file.".config/hyprextra/" = {
        source = ./hyprextra;
        recursive = true;
      };

      # Runtime dependency of scripts/niri-swap-external.sh, which parses
      # `niri msg --json outputs` to decide which way to flip the external
      # monitor.
      home.packages = [ pkgs.jq ];
    });
  };
}
