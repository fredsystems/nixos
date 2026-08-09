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
    home-manager.users = lib.genAttrs allUsers (_userName: {
      programs.opencode = {
        enable = true;
        settings = {
          "$schema" = "https://opencode.ai/config.json";

          permission = {
            # `external_directory` defaults to "ask", which stalls any
            # unattended session the moment an agent reads a dependency's
            # real source to write code against its actual API surface
            # rather than a hallucinated one. These are read-only
            # reference trees; opencode expands `~` itself, so the same
            # patterns are correct on darwin.
            external_directory = {
              "~/.cargo/registry/src/**" = "allow";
              "~/.cargo/git/checkouts/**" = "allow";
              "~/.rustup/toolchains/**" = "allow";
              "/nix/store/**" = "allow";
            };

            # Directories allowed above inherit the workspace defaults,
            # and `edit` defaults to "allow" -- so without these denies
            # the allowances above would also hand out write access to
            # the dependency caches. Catch-all first: last match wins.
            edit = {
              "*" = "allow";
              "~/.cargo/**" = "deny";
              "~/.rustup/**" = "deny";
              "/nix/store/**" = "deny";
            };
          };
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
    });
  };
}
