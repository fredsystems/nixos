{
  lib,
  config,
  user,
  ...
}:
let
  cfg = config.desktop.onepassword;
in
{
  options.desktop.onepassword = {
    enable = lib.mkEnableOption "1Password";
  };

  config = lib.mkIf cfg.enable {
    programs._1password.enable = true;
    programs._1password-gui = {
      enable = true;
      polkitPolicyOwners = [ "${user}" ];
    };
  };
}
