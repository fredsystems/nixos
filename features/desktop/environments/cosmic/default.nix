{
  lib,
  config,
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
  };
}
