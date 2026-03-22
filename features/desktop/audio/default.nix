{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.desktop.audio;
in
{
  options.desktop.audio = {
    enable = lib.mkEnableOption "Audio";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      pavucontrol
      crosspipe
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
