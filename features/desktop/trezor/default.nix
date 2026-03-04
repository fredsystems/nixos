{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.desktop.trezor;
in
{
  options.desktop.trezor = {
    enable = mkOption {
      description = "Enable Trezor.";
      default = false;
    };
  };

  config = mkIf cfg.enable {
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
