{
  lib,
  config,
  ...
}:
let
  cfg = config.desktop.wireshark;
in
{
  options.desktop.wireshark = {
    enable = lib.mkEnableOption "Wireshark";
  };

  config = lib.mkIf cfg.enable {

    programs.wireshark = {
      enable = true;
      dumpcap.enable = true;
    };
  };
}
