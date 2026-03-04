{
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

      programs.tmux = {
        enable = true;
        clock24 = true;

        extraConfig = ''
                    # ---------- Terminal Settings ----------
          set -g default-terminal "tmux-256color"
          set -ga terminal-overrides ",*:RGB"
          set -g mouse on
          set -g set-clipboard on

          # ---------- Prefix ----------
          unbind C-b
          set -g prefix C-a
          bind-key C-a send-prefix

          # ---------- Pane Navigation (vim-style) ----------
          bind h select-pane -L
          bind j select-pane -D
          bind k select-pane -U
          bind l select-pane -R

          unbind %
          unbind '"'

          bind '/' split-window -h -c "#{pane_current_path}"
          bind % split-window -v -c "#{pane_current_path}"

          unbind r
          bind r source-file ~/.config/tmux/tmux.conf \; display-message "Reloaded tmux.conf"

          # ---------- Indexing ----------
          set -g base-index 1
          set -g pane-base-index 1
          set-window-option -g pane-base-index 1
          set-option -g renumber-windows on

          # ---------- Copy Mode (vim-style) ----------
          set-window-option -g mode-keys vi
          bind-key -T copy-mode-vi v send-keys -X begin-selection
          bind-key -T copy-mode-vi C-v send-keys -X rectangle-toggle
          bind-key -T copy-mode-vi y send-keys -X copy-selection-and-cancel
          unbind -T copy-mode-vi MouseDragEnd1Pane

          # ---------- Alt + hjkl to switch panes ----------
          bind -n M-h select-pane -L
          bind -n M-j select-pane -D
          bind -n M-k select-pane -U
          bind -n M-l select-pane -R

          # ---------- Alt + number to select window ----------
          bind -n M-1 select-window -t 1
          bind -n M-2 select-window -t 2
          bind -n M-3 select-window -t 3
          bind -n M-4 select-window -t 4
          bind -n M-5 select-window -t 5
          bind -n M-6 select-window -t 6
          bind -n M-7 select-window -t 7
          bind -n M-8 select-window -t 8
          bind -n M-9 select-window -t 9

          # ---------- Catppuccin Mocha Palette ----------
          # base:      #1e1e2e
          # mantle:    #181825
          # crust:     #11111b
          # text:      #cdd6f4
          # subtext1:  #bac2de
          # subtext0:  #a6adc8
          # overlay2:  #9399b2
          # overlay1:  #7f849c
          # overlay0:  #6c7086
          # surface2:  #585b70
          # surface1:  #45475a
          # surface0:  #313244
          # blue:      #89b4fa
          # lavender:  #b4befe
          # sapphire:  #74c7ec
          # sky:       #89dceb
          # teal:      #94e2d5
          # green:     #a6e3a1
          # yellow:    #f9e2af
          # peach:     #fab387
          # maroon:    #eba0ac
          # red:       #f38ba8
          # mauve:     #cba6f7
          # pink:      #f5c2e7
          # flamingo:  #f2cdcd
          # rosewater: #f5e0dc

          # ---------- Status Bar ----------
          set -g status on
          set -g status-bg "#1e1e2e"
          set -g status-justify "left"
          set -g status-left-length 100
          set -g status-right-length 100

          # ---------- Messages ----------
          set -g message-style "fg=#89b4fa,bg=#585b70,align=centre"
          set -g message-command-style "fg=#89b4fa,bg=#585b70,align=centre"

          # ---------- Pane Borders ----------
          set -g pane-border-style "fg=#585b70"
          set -g pane-active-border-style "fg=#89b4fa"

          # ---------- Window Status ----------
          set -g window-status-style "fg=#cdd6f4,bg=#1e1e2e"
          set -g window-status-activity-style "fg=#cdd6f4,bg=#1e1e2e"
          set -g window-status-separator ""

          # Current window format
          set -g window-status-current-format "#[fg=#89b4fa,bg=#1e1e2e] #I: #[fg=#cba6f7,bg=#1e1e2e](✓) #[fg=#94e2d5,bg=#1e1e2e]#(echo '#{pane_current_path}' | rev | cut -d'/' -f-2 | rev) #[fg=#cba6f7,bg=#1e1e2e]"

          # Normal window format
          set -g window-status-format "#[fg=#89b4fa,bg=#1e1e2e] #I: #[fg=#cdd6f4,bg=#1e1e2e]#W"

          # ---------- Status Right ----------
          set -g status-right "#[fg=#89b4fa,bg=#1e1e2e,nobold,nounderscore,noitalics]#[fg=#1e1e2e,bg=#89b4fa] #[fg=#cdd6f4,bg=#585b70] #W #{?client_prefix,#[fg=#cba6f7],#[fg=#94e2d5]}#[bg=#585b70]#{?client_prefix,#[bg=#cba6f7],#[bg=#94e2d5]}#[fg=#1e1e2e] #[fg=#cdd6f4,bg=#585b70] #S "

          # ---------- Clock & Mode ----------
          set -g clock-mode-colour "#89b4fa"
          set -g mode-style "fg=#89b4fa,bg=#585b70,bold"

          # ---------- End ----------

        '';
      };
    });
  };
}
