{
  lib,
  pkgs,
  config,
  user,
  extraUsers ? [ ],
  ...
}:
with lib;
let
  username = user;
  allUsers = [ user ] ++ extraUsers;
  cfg = config.desktop.ledger;
in
{
  options.desktop.ledger = {
    enable = mkOption {
      description = "Install Ledger Live desktop application.";
      default = false;
    };
  };

  config = mkIf cfg.enable {
    hardware.ledger.enable = true;

    services = {
      udev.packages = with pkgs; [
        ledger-udev-rules
        # potentially even more if you need them
      ];
    };

    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        ledger-live-desktop
      ];
    });
  };
}
