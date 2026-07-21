{
  pkgs,
  user,
  extraUsers ? [ ],
  lib,
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;
in
{
  config = {
    home-manager.users = lib.genAttrs allUsers (_: {
      home.packages = with pkgs; [
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
        # piper.yazi previewers below shell out to these
        gnutar
        glow
        hexyl
        sqlite
      ];

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
