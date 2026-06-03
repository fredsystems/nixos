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

  # Skills directory is baked into the derivation at build time. The path is
  # resolved relative to this file (`features/ai/opencode/default.nix`) and
  # walks back up to the repo root, then into `.opencode/skills/`. Nix copies
  # the contents into the store, so the resulting derivation is fully
  # self-contained -- Colmena-deployed targets do not need the source
  # checkout (or any `~/GitHub/nixos/`) to exist on the deployed host.
  skillsSource = ../../../.opencode/skills;
in
{
  options.ai.opencode = {
    enable = lib.mkEnableOption "OpenCode LLM stack";
  };

  config = lib.mkIf cfg.enable {
    home-manager.users = lib.genAttrs allUsers (
      _userName: _: {
        programs.opencode = {
          enable = true;
          settings = {
            "$schema" = "https://opencode.ai/config.json";
          };
        };

        # opencode auto-scans `~/.config/opencode/skills/**/SKILL.md`, so
        # placing the baked-in skills tree there is sufficient -- no
        # `skills.paths` entry is required. `recursive = true` mirrors the
        # directory contents (one symlink per file) rather than symlinking
        # the top-level directory itself, which would break opencode's
        # ability to scan sub-folders managed alongside non-managed ones.
        home.file.".config/opencode/skills" = {
          source = skillsSource;
          recursive = true;
        };

        catppuccin.opencode.enable = true;
      }
    );
  };
}
