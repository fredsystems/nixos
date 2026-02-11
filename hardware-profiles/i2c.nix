{
  config,
  lib,
  user,
  ...
}:
{
  options.hardware-profile.i2c = {
    enable = lib.mkEnableOption "I2C device support";
  };

  config = lib.mkIf config.hardware-profile.i2c.enable {
    hardware.i2c.enable = lib.mkDefault true;
    users.users.${user}.extraGroups = lib.mkDefault [ "i2c" ];
  };
}
