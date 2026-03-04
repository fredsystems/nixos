{
  lib,
  config,
  ...
}:
with lib;
let
  cfg = config.desktop.print;
in
{
  options.desktop.print = {
    enable = mkOption {
      description = "Install printing services.";
      default = false;
    };
  };

  config = mkIf cfg.enable {
    # Enable CUPS to print documents.
    services.printing.enable = true;

    services.avahi = {
      enable = true;
      nssmdns4 = true;
      openFirewall = true;
    };
  };
}
