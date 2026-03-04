{
  lib,
  config,
  ...
}:
with lib;
let
  cfg = config.desktop.steam;
in
{
  options.desktop.steam = {
    enable = mkOption {
      description = "Enable Steam.";
      default = false;
    };
  };

  config = mkIf cfg.enable {
    programs.steam = {
      enable = true;
      remotePlay.openFirewall = true; # Open ports in the firewall for Steam Remote Play
      dedicatedServer.openFirewall = true; # Open ports in the firewall for Source Dedicated Server
      localNetworkGameTransfers.openFirewall = true; # Open ports in the firewall for Steam Local Network Game Transfers
    };
  };
}
