{
  pkgs,
  user,
  extraUsers ? [ ],
  lib,
  system,
  nixYaziPluginsInput,
  isDarwin ? false,
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;
in
{
  config = {
    home-manager.users = lib.genAttrs allUsers (_: {
      # nix-yazi-plugins's home-manager module — used for plugins that need
      # more than a static plugin-directory link (e.g. starship.yazi's
      # require("starship"):setup() call in init.lua). Plugins that are
      # just a directory link (clipboard, piper above) go straight through
      # home-manager's own `programs.yazi.plugins`/`settings` instead.
      imports = [
        nixYaziPluginsInput.legacyPackages.${system}.homeManagerModules.default
      ];

      home.packages =
        (with pkgs; [
          # plugins for yazi
          ffmpeg
          p7zip
          jq
          poppler
          fd
          ripgrep
          fzf
          zoxide
          imagemagick
          # piper.yazi previewers below shell out to these. bat/eza are
          # already installed repo-wide (features/shell/bat,
          # features/shell/eza) and glow/hexyl/sqlite have no other
          # provider, but all five are declared explicitly here so this
          # file's dependencies are correct on their own, regardless of
          # what else is enabled elsewhere.
          bat
          eza
          glow
          hexyl
          sqlite
        ])
        # gnutar also backs the tar previewer above, but its `bin/tar`
        # collides with the `toybox` package profiles/darwin.nix already
        # installs for Darwin hosts (pkgs.buildEnv: conflicting subpath).
        # Darwin's toybox-provided `tar` covers the same previewer command.
        ++ lib.optionals (!isDarwin) [ pkgs.gnutar ];

      programs.yazi = {
        enable = true;
        # FIXME: Remove when all versions of our systems are 26.05 or later
        shellWrapperName = "y";

        plugins = {
          # XYenon/clipboard.yazi, packaged directly in nixpkgs (no need for
          # the nix-yazi-plugins flake input here). Cross-platform (Linux
          # X11/Wayland via xclip/wl-copy, macOS via osascript) and uses the
          # modern `cx.yanked` API rather than `tab.selected`, so it doesn't
          # trip yazi's yank-API deprecation warning. On hosts without a
          # display server (servers over SSH) it silently no-ops instead of
          # erroring. `wl-copy`/`wl-paste` are already provided on the
          # desktop hosts by desktop.environments.modules.clipboard.
          clipboard = pkgs.yaziPlugins.clipboard;

          # yazi-rs/plugins:piper — pipes any shell command's output in as a
          # previewer. Generic on its own; the actual previewer bindings are
          # configured below in `settings.plugin`.
          # https://github.com/yazi-rs/plugins/tree/main/piper.yazi
          piper = pkgs.yaziPlugins.piper;
        };

        yaziPlugins = {
          enable = true;
          plugins = {
            # Rolv-Apneseth/starship.yazi: shows the starship prompt
            # (already enabled repo-wide in features/shell/starship) as
            # yazi's header. Handles generating the
            # require("starship"):setup() init.lua call for us.
            starship.enable = true;

            # yazi-rs/plugins:smart-filter — continuous filtering,
            # auto-enters a uniquely-matched directory, opens the file on
            # submit. Default keybind ("F") comes from the plugin's own
            # hm-module, merged into keymap.mgr.prepend_keymap below.
            smart-filter.enable = true;
          };
        };

        settings.plugin = {
          prepend_previewers = [
            # List tarball contents instead of dumping raw bytes.
            {
              url = "*.tar*";
              run = ''piper --format=url -- tar tf "$1"'';
            }
            # bat already carries the repo's catppuccin theme
            # (catppuccin.bat.enable in features/shell/bat).
            {
              url = "*.csv";
              run = ''piper -- bat -p --color=always "$1"'';
            }
            {
              url = "*.md";
              run = ''piper -- CLICOLOR_FORCE=1 glow -w=$w -s=dark "$1"'';
            }
            {
              url = "*/";
              run = ''piper -- eza -TL=3 --color=always --icons=always --group-directories-first --no-quotes "$1"'';
            }
            {
              mime = "application/sqlite3";
              run = ''piper -- sqlite3 "$1" ".schema --indent"'';
            }
          ];

          # Fallback previewer for anything with no more specific match
          # above (yazi otherwise falls back to `file -bL "$1"`).
          append_previewers = [
            {
              url = "*";
              run = ''piper -- hexyl --border=none --terminal-width=$w "$1"'';
            }
          ];
        };

        # Wrap the default yank ("y") / cut ("x") keys to also sync the
        # yanked paths to the system clipboard, and add Ctrl+P to paste
        # files from the system clipboard into the current directory. See
        # https://github.com/XYenon/clipboard.yazi for the upstream keymap.
        keymap.mgr.prepend_keymap = [
          {
            on = "y";
            run = [
              "yank"
              "plugin clipboard -- --action=copy"
            ];
            desc = "Yank selected files (copy)";
          }
          {
            on = "x";
            run = [
              "yank --cut"
              "plugin clipboard -- --action=copy"
            ];
            desc = "Yank selected files (cut)";
          }
          {
            on = [ "<C-p>" ];
            run = "plugin clipboard -- --action=paste";
            desc = "Paste files from the system clipboard";
          }
        ];
      };

      catppuccin.yazi.enable = true;
    });
  };
}
