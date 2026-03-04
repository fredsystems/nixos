{
  lib,
  config,
  user,
  extraUsers ? [ ],
  ...
}:
with lib;
let
  cfg = config.ai.opencode;
  allUsers = [ user ] ++ extraUsers;
in
{
  options.ai.opencode = {
    enable = mkEnableOption "Enable OpenCode LLM stack.";
  };

  config = mkIf cfg.enable {
    home-manager.users = lib.genAttrs allUsers (_: {
      programs.opencode = {
        enable = true;
      };

      catppuccin.opencode.enable = true;
    });
  };
}
