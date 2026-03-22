{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.desktop.trezor;
in
{
  options.desktop.trezor = {
    enable = lib.mkEnableOption "Trezor";
  };

  config = lib.mkIf cfg.enable {
    services = {
      trezord = {
        enable = true;
      };

      udev.packages = with pkgs; [
        trezor-udev-rules
      ];
    };

    environment.systemPackages = with pkgs; [
      trezor-suite
    ];
  };
}
