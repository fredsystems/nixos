{
  config,
  lib,
  ...
}:
let
  user = config.shared.user.name;
in
{
  # Declares the shared.user.name this module reads, so the exported
  # hardware module works standalone (the builders import it too; the module
  # system de-duplicates it).
  imports = [ ../base/fleet-identity.nix ];

  options.hardware-profile.i2c = {
    enable = lib.mkEnableOption "I2C device support";
  };

  config = lib.mkIf config.hardware-profile.i2c.enable {
    hardware.i2c.enable = lib.mkDefault true;
    users.users.${user}.extraGroups = [ "i2c" ];
  };
}
