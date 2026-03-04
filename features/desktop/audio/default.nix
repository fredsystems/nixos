{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.desktop.audio;
in
{
  options.desktop.audio = {
    enable = mkOption {
      description = "Enable Audio.";
      default = false;
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      pavucontrol
      helvum
    ];

    security.rtkit.enable = true;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
    };
  };
}
