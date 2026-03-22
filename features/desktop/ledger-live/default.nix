{
  lib,
  pkgs,
  config,
  user,
  extraUsers ? [ ],
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;
  cfg = config.desktop.ledger;
in
{
  options.desktop.ledger = {
    enable = lib.mkEnableOption "Ledger Live desktop application";
  };

  config = lib.mkIf cfg.enable {
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
