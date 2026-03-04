{
  lib,
  config,
  ...
}:
with lib;
let
  cfg = config.desktop.wireshark;
in
{
  options.desktop.wireshark = {
    enable = mkOption {
      description = "Enable Wireshark.";
      default = false;
    };
  };

  config = mkIf cfg.enable {

    programs.wireshark = {
      enable = true;
      dumpcap.enable = true;
    };
  };
}
