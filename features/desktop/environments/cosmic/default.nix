{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.desktop.environments.cosmic;
in
{
  options.desktop.environments.cosmic = {
    enable = lib.mkEnableOption "Cosmic";
  };

  config = lib.mkIf cfg.enable {
    services.desktopManager.cosmic.enable = true;

    # See deployment.criticalProcesses in modules/base/deployment-meta.nix.
    deployment.criticalProcesses.cosmic-comp = {
      package = pkgs.cosmic-comp;
      reason = "the running compositor; activation never restarts it, so a version bump leaves the session on the old cosmic-comp under a new COSMIC shell";
    };
  };
}
