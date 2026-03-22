{
  lib,
  config,
  ...
}:
let
  cfg = config.ai;
in
{
  options.ai = {
    enable = lib.mkEnableOption "AI LLM support";
  };

  imports = [
    ./lammacpp
    ./opencode
  ];

  config = lib.mkIf cfg.enable {
    ai.local-llm.enable = true;
    ai.opencode.enable = true;
  };
}
