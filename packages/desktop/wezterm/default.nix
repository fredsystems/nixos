{
  lib,
  config,
  user,
  system,
  ...
}:

let
  username = user;
  cfg = config.desktop.wezterm;

  # Pull shared settings from terminal/common.nix
  t = config.terminal;

  isDarwin = lib.hasSuffix "darwin" system;
  isLinux = !isDarwin;
in
{
  options.desktop.wezterm = {
    enable = lib.mkEnableOption "Enable WezTerm terminal emulator";
  };

  imports = [ ../../../modules/terminal/common.nix ] ++ lib.optional isLinux ./linux-xdg.nix;

  config = lib.mkIf cfg.enable {
    home-manager.users.${username} = {
      programs.wezterm = {
        enable = true;

        # Generate wezterm.lua from Nix
        extraConfig = ''
          local wezterm = require("wezterm")
          local config = wezterm.config_builder()

          -- Shared Font
          config.font = wezterm.font("${t.font.family}")
          config.font_size = ${toString t.font.size}

          -- General Terminal Behavior
          config.enable_wayland = ${if t.enableWayland then "true" else "false"}
          config.term = "wezterm"
          config.color_scheme = "${t.theme}"
          config.window_background_opacity = ${toString t.opacity}
          config.hide_tab_bar_if_only_one_tab = true

          -- macOS/Linux keybindings
          local act = wezterm.action
          config.keys = {
            { mods = "OPT", key = "LeftArrow",  action = act.SendKey({ mods = "ALT",  key = "b" }) },
            { mods = "OPT", key = "RightArrow", action = act.SendKey({ mods = "ALT",  key = "f" }) },
            { mods = "CMD", key = "LeftArrow",  action = act.SendKey({ mods = "CTRL", key = "a" }) },
            { mods = "CMD", key = "RightArrow", action = act.SendKey({ mods = "CTRL", key = "e" }) },
            { mods = "CMD", key = "Backspace",  action = act.SendKey({ mods = "CTRL", key = "u" }) },

            -- Tab navigation
            { mods = "CMD|OPT",   key = "LeftArrow",  action = act.ActivateTabRelative(-1) },
            { mods = "CMD|OPT",   key = "RightArrow", action = act.ActivateTabRelative(1) },
            { mods = "CMD|SHIFT", key = "LeftArrow",  action = act.ActivateTabRelative(-1) },
            { mods = "CMD|SHIFT", key = "RightArrow", action = act.ActivateTabRelative(1) },
          }

          return config
        '';
      };

      # Catppuccin theme integration
      catppuccin.wezterm.enable = true;
      catppuccin.wezterm.apply = true;
    };
  };
}
