{
  inputs,
  lib,
  config,
  ...
}:
let
  cfg = config.desktop.freminal;
in
{
  options.desktop.freminal = {
    enable = lib.mkEnableOption "Enable freminal terminal emulator";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      inputs.freminal.packages.${config.nixpkgs.hostPlatform.system}.freminal
    ];
  };
}
