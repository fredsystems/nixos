{
  lib,
  config,
  ...
}:
with lib;
let
  cfg = config.desktop.environments.cosmic;
in
{
  options.desktop.environments.cosmic = {
    enable = mkOption {
      description = "Enable Cosmic.";
      default = false;
    };
  };

  config = mkIf cfg.enable {
    services.desktopManager.cosmic.enable = true;
  };
}
