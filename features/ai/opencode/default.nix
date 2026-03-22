{
  lib,
  config,
  user,
  extraUsers ? [ ],
  ...
}:
let
  cfg = config.ai.opencode;
  allUsers = [ user ] ++ extraUsers;
in
{
  options.ai.opencode = {
    enable = lib.mkEnableOption "OpenCode LLM stack";
  };

  config = lib.mkIf cfg.enable {
    home-manager.users = lib.genAttrs allUsers (_: {
      programs.opencode = {
        enable = true;
      };

      catppuccin.opencode.enable = true;
    });
  };
}
