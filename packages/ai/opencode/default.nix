{
  lib,
  config,
  user,
  ...
}:
with lib;
let
  cfg = config.ai.opencode;
in
{
  options.ai.opencode = {
    enable = mkEnableOption "Enable OpenCode LLM stack.";
  };

  config = mkIf cfg.enable {
    home-manager.users.${user} = {
      programs.opencode = {
        enable = true;
      };

      catppuccin.opencode.enable = true;
    };
  };
}
