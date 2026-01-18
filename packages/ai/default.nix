{
  lib,
  config,
  ...
}:
with lib;
let
  cfg = config.ai;
in
{
  options.ai = {
    enable = mkOption {
      description = "Enable AI LLM support.";
      default = false;
    };
  };

  imports = [
    ./lammacpp
    ./opencode
  ];

  config = mkIf cfg.enable {
    ai.local-llm.enable = true;
    ai.opencode.enable = true;
  };
}
