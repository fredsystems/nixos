{
  lib,
  config,
  ...
}:
let
  cfg = config.desktop.print;
in
{
  options.desktop.print = {
    enable = lib.mkEnableOption "printing services";
  };

  config = lib.mkIf cfg.enable {
    # Enable CUPS to print documents.
    services.printing.enable = true;

    services.avahi = {
      enable = true;
      nssmdns4 = true;
      openFirewall = true;
    };
  };
}
