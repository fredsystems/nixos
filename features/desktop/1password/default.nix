{
  lib,
  config,
  user,
  ...
}:
with lib;
let
  cfg = config.desktop.onepassword;
  username = user;
in
{
  options.desktop.onepassword = {
    enable = mkOption {
      description = "Enable 1Password.";
      default = false;
    };
  };

  config = mkIf cfg.enable {
    programs._1password.enable = true;
    programs._1password-gui = {
      enable = true;
      polkitPolicyOwners = [ "${username}" ];
    };
  };
}
