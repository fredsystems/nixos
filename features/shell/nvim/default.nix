{
  user,
  extraUsers ? [ ],
  lib,
  system,
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;
in
{
  config = {
    home-manager.users = lib.genAttrs allUsers (
      _:
      {
        pkgs,
        ...
      }:
      {
        # install ripgrep via pkgs

        home.packages = with pkgs; [
          ripgrep
          tectonic
          mermaid-cli
          ghostscript
        ];

        programs.nixvim = {
          defaultEditor = true;
          enable = true;

          # Allow unfree-tagged plugins (e.g. git-conflict.nvim) in nixvim's
          # internal pkgs instance. The host's nixpkgs.config does not propagate
          # to nixvim's bundled nixpkgs, so this must be set explicitly here.
          #
          # Setting nixpkgs.config forces nixvim to construct its own pkgs from
          # its bundled nixpkgs (intentional: a host nixpkgs bump must not break
          # nvim). The home-manager wrapper defaults nixvim's host/buildPlatform
          # to the host's pkgs.stdenv.{host,build}Platform; on recent
          # nixos-unstable resolving those re-enters the host evaluation and
          # causes infinite recursion in the lsp/servers modules. Pin both
          # platforms to the literal `system` string (not pkgs.stdenv.*, which
          # would force the host pkgs evaluation that is itself part of the
          # cycle) to break the recursion while keeping nixvim on its own
          # nixpkgs.
          nixpkgs = {
            config.allowUnfree = true;
            hostPlatform = system;
            buildPlatform = system;
          };

          colorscheme = "catppuccin";
          colorschemes.catppuccin = {
            enable = true;
            settings = {
              flavour = "mocha";
            };
          };

          extraPlugins = with pkgs.vimPlugins; [
            direnv-vim
            zellij-nvim
            nvim-lspconfig
          ];

          # No real Rust toolchain here on purpose (see the rust_analyzer LSP
          # comment below): it's provided per-project via a flake devShell.
          # But nvim-lspconfig's rust_analyzer `root_dir()` unconditionally
          # shells out to `rustc --print sysroot` on *every* .rs buffer via
          # `vim.system(...):wait()`, which throws a hard, uncaught Lua error
          # (ENOENT) rather than failing gracefully when `rustc` doesn't
          # exist anywhere on $PATH -- exactly the state you're in before a
          # project's direnv-provided devShell has loaded. These are inert
          # stubs (always exit 1) added to the *end* of nvim's PATH
          # (`extraPackagesAfter` = `--suffix PATH`, same fallback mechanism
          # as `packageFallback`), purely so that shell-out fails cleanly
          # instead of crashing. A real project-provided `rustc`/`cargo` from
          # direnv still wins, since it's earlier in $PATH.
          extraPackagesAfter = [
            (pkgs.writeShellScriptBin "rustc" "exit 1")
            (pkgs.writeShellScriptBin "cargo" "exit 1")
          ];

          extraConfigLuaPre = ''
            -- Consider a "normal" buffer as: loaded, listed, and not special buftype
            local function has_normal_buffer()
              for _, b in ipairs(vim.api.nvim_list_bufs()) do
                if vim.api.nvim_buf_is_loaded(b) and vim.fn.buflisted(b) == 1 then
                  local bt = vim.api.nvim_get_option_value("buftype", { buf = b })
                  if bt == "" then
                    return true
                  end
                end
              end
              return false
            end

            -- Smart buffer close: switches to another buffer before deleting,
            -- keeping the explorer and window layout intact.
            function _G.smart_close_buffer(bufnr)
              bufnr = bufnr or vim.api.nvim_get_current_buf()
              if type(bufnr) == "string" then bufnr = tonumber(bufnr) end

              -- Don't close special buffers (explorer, etc.)
              local ok, ft = pcall(function() return vim.bo[bufnr].filetype end)
              if ok and (ft == "snacks_layout_box" or ft == "snacks_picker_list" or ft == "snacks_explorer") then
                return
              end

              -- Find another normal listed buffer to switch to
              local alt_buf = nil
              for _, b in ipairs(vim.api.nvim_list_bufs()) do
                if b ~= bufnr and vim.api.nvim_buf_is_loaded(b) and vim.fn.buflisted(b) == 1 then
                  local bt = vim.api.nvim_get_option_value("buftype", { buf = b })
                  if bt == "" then
                    alt_buf = b
                    break
                  end
                end
              end

              if alt_buf then
                -- Switch any window showing this buffer to the alternate buffer
                for _, win in ipairs(vim.api.nvim_list_wins()) do
                  if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
                    vim.api.nvim_win_set_buf(win, alt_buf)
                  end
                end
                vim.api.nvim_buf_delete(bufnr, { force = true })
              else
                -- Last normal buffer: keep window alive with an empty buffer
                vim.cmd("enew")
                vim.api.nvim_buf_delete(bufnr, { force = true })
              end
            end
          '';

          extraConfigLua = ''
                                          -- Configure blink-cmp formatting with lspkind
                                          require('blink.cmp').setup({
                                            appearance = {
                                              use_nvim_cmp_as_default = true,
                                            },
                                            completion = {
                                              formatting = {
                                                format = require("lspkind").cmp_format({
                                                  mode = "symbol_text",
                                                  maxwidth = 50,
                                                  ellipsis_char = "...",
                                                }),
                                              },
                                            },
                                          })


                        vim.api.nvim_create_user_command("Qa", "qa", {})

            -- Auto-reload files modified externally
            vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold", "CursorHoldI" }, {
              callback = function()
                if vim.api.nvim_get_mode().mode ~= "c" then
                  vim.cmd("checktime")
                end
              end,
            })
            vim.api.nvim_create_autocmd("FileChangedShellPost", {
              callback = function()
                vim.notify("File changed on disk. Buffer reloaded.", vim.log.levels.WARN)
              end,
            })

            -- Deliberately NOT using virtual_text or virtual_lines: neither
            -- can show a long diagnostic message in full (virtual_text never
            -- wraps; virtual_lines' "scroll" overflow mode degrades to
            -- truncation when 'wrap' is on, which it is here) -- both were
            -- rendering the same message cut off, twice, on screen at once.
            -- Underline + sign column (both on by default) mark *that* a
            -- line has a problem; a floating window (wrap = true by
            -- default) on CursorHold is the only place the complete,
            -- wrapped message is shown, so that's the only diagnostic UI
            -- left enabled.
            vim.diagnostic.config({ virtual_text = false, virtual_lines = false })

            -- We track our own float's winid instead of bailing out whenever
            -- *any* floating window has a zindex (blink-cmp's menu, snacks
            -- notifications, noice popups, ...), which previously
            -- suppressed this far too often.
            local diagnostic_float_winid = nil
            vim.api.nvim_create_autocmd({ "CursorHold" }, {
                pattern = "*",
                callback = function()
                    if diagnostic_float_winid and vim.api.nvim_win_is_valid(diagnostic_float_winid) then
                        return
                    end
                    local _, winid = vim.diagnostic.open_float({
                        scope = "cursor",
                        focusable = false,
                        border = "rounded",
                        close_events = {
                            "CursorMoved",
                            "CursorMovedI",
                            "BufHidden",
                            "InsertCharPre",
                            "WinLeave",
                        },
                    })
                    diagnostic_float_winid = winid
                end
            })

            -- Feed gitsigns hunks onto the scrollview scrollbar as a sign
            -- group (scrollview only has this wired for its built-in groups;
            -- gitsigns integration is an opt-in contrib module).
            require('scrollview.contrib.gitsigns').setup()

            -- Fix Home/End keys in tmux
            -- Nvim's terminal layer converts raw escape sequences into internal
            -- key names BEFORE keymaps are checked. For example \x1b[1~ becomes
            -- <Find> (VT220) instead of <Home>. We must map both the internal
            -- key names AND raw sequences to cover all code paths.
            local modes = {'n', 'i', 'v', 'c'}

            -- Map VT220 internal key names that nvim resolves to
            vim.keymap.set(modes, '<Find>',   '<Home>', {silent = true, noremap = true})
            vim.keymap.set(modes, '<Select>', '<End>',  {silent = true, noremap = true})

            -- Also map raw escape sequences as a fallback in case terminfo
            -- doesn't recognise them and they pass through verbatim
            local home_seqs = {'\x1bOH', '\x1b[H', '\x1b[1~', '\x1b[7~'}
            local end_seqs  = {'\x1bOF', '\x1b[F', '\x1b[4~', '\x1b[8~'}
            for _, seq in ipairs(home_seqs) do
              vim.keymap.set(modes, seq, '<Home>', {silent = true, noremap = true})
            end
            for _, seq in ipairs(end_seqs) do
              vim.keymap.set(modes, seq, '<End>', {silent = true, noremap = true})
            end

            -- The "" / "" overflow markers bufferline draws at each end of
            -- the tab bar when there are more buffers than fit on screen are
            -- purely decorative counts -- bufferline never wires a click
            -- handler to them (only actual buffer tabs get one), so clicking
            -- them falls through to Neovim's own default 'tabline' click
            -- behaviour, which switches *real* tabpages (almost always a
            -- no-op with a single tabpage). Whatever appeared to work on the
            -- right was landing on the adjacent, genuinely clickable last
            -- buffer tab, not the marker itself scrolling anything.
            -- Mouse-wheel over the tabline is real: only fires while the
            -- mouse is on row 1 (the tabline), leaving wheel-scroll inside
            -- normal windows untouched.
            local function tabline_wheel_or_default(key, bufferline_cmd)
              return function()
                if vim.fn.getmousepos().screenrow == 1 then
                  vim.cmd(bufferline_cmd)
                else
                  -- Not over the tabline: replay the key non-remappably so
                  -- normal window scrolling is unaffected.
                  local termcode = vim.api.nvim_replace_termcodes(key, true, true, true)
                  vim.api.nvim_feedkeys(termcode, 'n', false)
                end
              end
            end
            vim.keymap.set('n', '<ScrollWheelUp>', tabline_wheel_or_default('<ScrollWheelUp>', 'BufferLineCyclePrev'))
            vim.keymap.set('n', '<ScrollWheelDown>', tabline_wheel_or_default('<ScrollWheelDown>', 'BufferLineCycleNext'))

                                          -- Fix for zellij.nvim health check
                                          vim.health = vim.health or {}
                                          vim.health.report_start = vim.health.report_start or function() end
                                          vim.health.report_ok = vim.health.report_ok or function() end
                                          vim.health.report_warn = vim.health.report_warn or function() end
                                          vim.health.report_error = vim.health.report_error or function() end
                                          vim.health.report_info = vim.health.report_info or function() end
          '';

          globals = {
            mapleader = " ";
            direnv_auto = 1;
            direnv_silent_load = 0;
          };

          highlight.ExtraWhitespace.bg = "red";

          keymaps = [
            # Buffer navigation
            {
              # BufferLineCycleNext/Prev (rather than :bnext/:bprevious)
              # follow the tab bar's own visual left-to-right order, which is
              # what the mouse-wheel-over-tabline mapping above also uses.
              action = "<cmd>BufferLineCycleNext<CR>";
              key = "<leader>bn";
              options.desc = "Next buffer";
            }
            {
              action = "<cmd>BufferLineCyclePrev<CR>";
              key = "<leader>bp";
              options.desc = "Previous buffer";
            }
            {
              action.__raw = "function() smart_close_buffer() end";
              key = "<leader>bd";
              options.desc = "Close buffer";
            }

            # LSP
            {
              action = "<cmd>LspInfo<CR>";
              key = "<leader>li";
              options.desc = "LSP Info";
            }
            {
              action = "<cmd>lua vim.lsp.buf.definition()<CR>";
              key = "gd";
              options.desc = "Go to definition";
            }
            {
              action = "<cmd>lua vim.lsp.buf.references()<CR>";
              key = "gr";
              options.desc = "Find references";
            }
            {
              key = "<leader>ca";
              action.__raw = "function() require('actions-preview').code_actions() end";
              options.desc = "Code actions";
            }
            {
              key = "<leader>zz";
              action.__raw = "function() Snacks.lazygit() end";
              options.desc = "Open LazyGit";
            }

            {
              key = "<leader>-";
              action.__raw = "function() Snacks.picker.explorer() end";
              options.desc = "Toggle Snacks Explorer";
            }

            {
              key = "<leader>rn";
              action.__raw = ''
                function()
                  return ":IncRename " .. vim.fn.expand("<cword>")
                end'';
              options.desc = "Incremental Rename";
              options.expr = true;
            }
            {
              key = "<leader>uc";
              action = "<cmd>Crates update_all_crates<CR>";
              options.desc = "Update all crates";
            }
            {
              key = "<leader>cu";
              action = "<cmd>Crates update_crate<CR>";
              options.desc = "Update crate on current line";
            }

            # Session management
            {
              key = "<leader>qs";
              action = "<cmd>SessionRestore<CR>";
              options.desc = "Restore session (cwd)";
            }
            {
              key = "<leader>qS";
              action = "<cmd>SessionSave<CR>";
              options.desc = "Save session";
            }
            {
              key = "<leader>qf";
              action = "<cmd>SessionSearch<CR>";
              options.desc = "Search sessions";
            }
            {
              key = "<leader>qd";
              action = "<cmd>SessionDelete<CR>";
              options.desc = "Delete session";
            }
          ];

          opts = {
            updatetime = 100;
            number = true;
            relativenumber = true;
            shiftwidth = 2;
            swapfile = false;
            undofile = true;
            incsearch = true;
            sessionoptions = "blank,buffers,curdir,folds,help,tabpages,winsize,winpos,terminal,localoptions";
            inccommand = "split";
            ignorecase = true;
            smartcase = true;
            signcolumn = "yes:2";
            autoread = true;
          };

          plugins = {
            bufferline = {
              enable = true;

              settings = {
                options = {
                  separator_style = "thin";
                  close_command.__raw = ''
                    function(bufnr)
                      smart_close_buffer(bufnr)
                    end
                  '';
                  offsets = [
                    {
                      filetype = "snacks_layout_box";
                      text = "󰙅  File Explorer";
                      separator = false;
                      text_align = "center";
                      highlight = "Directory";
                    }
                  ];
                };
              };
            };

            # Performant, batteries-included completion plugin for Neovim.
            blink-cmp = {
              enable = true;
              setupLspCapabilities = true;
              settings = {
                appearance = {
                  nerd_font_variant = "normal";
                  use_nvim_cmp_as_default = true;
                };
                # "enter" preset: <CR> accepts the selected completion item
                # (falls back to a normal newline when the menu isn't open).
                # <Tab>/<S-Tab> are left alone for snippet-placeholder
                # navigation, matching the library default's separation of
                # "accept" from "snippet jump".
                keymap.preset = "enter";
                cmdline = {
                  enabled = true;
                  keymap = {
                    preset = "inherit";
                  };
                  completion = {
                    list.selection.preselect = false;
                    menu = {
                      auto_show = true;
                    };
                    ghost_text = {
                      enabled = true;
                    };
                  };
                };
                completion = {
                  menu.border = "rounded";
                  accept = {
                    auto_brackets = {
                      enabled = true;
                      semantic_token_resolution.enabled = false;
                    };
                  };
                  documentation = {
                    auto_show = true;
                    window.border = "rounded";
                  };
                };
                # blink.cmp's own signature help, shown next to the
                # completion menu. Disabled by default; noice.nvim also has
                # an auto-popup signature helper, but this one is more
                # tightly integrated with the completion popup itself.
                signature = {
                  enabled = true;
                  window.border = "rounded";
                };
                sources = {
                  default = [
                    "lsp"
                    "buffer"
                    "path"
                    "snippets"
                    "copilot"
                    "emoji"
                  ];
                  providers = {
                    buffer = {
                      enabled = true;
                      score_offset = 0;
                    };
                    lsp = {
                      name = "LSP";
                      enabled = true;
                      score_offset = 10;
                    };
                    emoji = {
                      name = "Emoji";
                      module = "blink-emoji";
                      score_offset = 1;
                    };
                    copilot = {
                      name = "copilot";
                      module = "blink-copilot";
                      async = true;
                      score_offset = 100;
                    };
                  };
                };
              };
            };

            # Compatibility layer for using nvim-cmp sources on blink.cmp
            blink-compat.enable = true;
            blink-copilot.enable = true;
            blink-emoji.enable = true;
            blink-indent.enable = true;
            blink-cmp-spell.enable = false;
            # Lightweight yet powerful formatter plugin for Neovim.
            conform-nvim = {
              enable = true;
              settings = {
                format_on_save = {
                  quiet = false;
                };
                formatters_by_ft = {
                  css = [ "prettier" ];
                  html = [ "prettier" ];
                  json = [ "prettier" ];
                  lua = [ "stylua" ];
                  markdown = [ "prettier" ];
                  nix = [ "nixfmt" ];
                  python = [ "black" ];
                  ruby = [ "rubyfmt" ];
                  yaml = [ "yamlfmt" ];
                  typescript = [
                    [
                      "prettierd"
                      "prettier"
                    ]
                  ];
                  bash = [ "shfmt" ];
                  sh = [ "shfmt" ];
                  javascript = [
                    [
                      "prettierd"
                      "prettier"
                    ]
                  ];
                  rust = [ "rustfmt" ];
                };
              };
            };

            crates = {
              enable = true;
              settings = {
                completion = {
                  crates = {
                    enabled = true;
                    max_results = 8;
                    min_chars = 3;
                  };
                };
              };
            };

            # VS Code-like pictograms for Neovim LSP completion items.
            lspkind = {
              enable = true;
              # not blink-cmp
              cmp.enable = false;
            };
            # premier Vim plugin for Git management.
            fugitive.enable = true;
            # powered fuzzy finder for Neovim written in Lua.
            fzf-lua = {
              enable = true;
              keymaps = {
                "<leader>sb" = {
                  action = "grep_curbuf";
                  options.desc = "Search Current Buffer";
                };
                "<leader>/" = {
                  action = "live_grep";
                  options.desc = "Live Grep";
                };
                "<leader>," = {
                  action = "buffers";
                  options.desc = "Switch Buffer";
                  settings = {
                    sort_mru = true;
                    sort_lastused = true;
                  };
                };
                "<leader>gc" = {
                  action = "git_commits";
                  options.desc = "Git Commits";
                };
                "<leader>gs" = {
                  action = "git_status";
                  options.desc = "Git Status";
                };
                "<leader>s\"" = {
                  action = "registers";
                  options.desc = "Registers";
                };
                "<leader>sd" = {
                  action = "diagnostics_document";
                  options.desc = "Document Diagnostics";
                };
                "<leader>sD" = {
                  action = "diagnostics_workspace";
                  options.desc = "Workspace Diagnostics";
                };
                "<leader>sh" = {
                  action = "help_tags";
                  options.desc = "Help Pages";
                };
                "<leader>sk" = {
                  action = "keymaps";
                  options.desc = "Key Maps";
                };
              };
            };
            # A plugin to visualize and resolve merge conflicts in neovim.
            git-conflict.enable = true;
            # Git hunk signs (add/change/delete) in the sign column, and the
            # data source for the scrollview scrollbar's git-modified regions.
            gitsigns.enable = true;
            # Shows a lightbulb sign whenever a code action is available at
            # the cursor, so "there is a fix here" is actually discoverable
            # instead of only working if you already know to press `gra`.
            nvim-lightbulb = {
              enable = true;
              settings.autocmd.enabled = true;
            };
            # Nicer code-action picker (with diff preview) than the bare
            # `vim.lsp.buf.code_action()` selection list. Auto-detects a
            # backend; falls back to the already-installed snacks picker
            # since telescope/mini.pick aren't installed here.
            actions-preview.enable = true;
            # Interactive scrollbar with signs for diagnostics (built in) and
            # git-modified regions (wired via the gitsigns contrib module in
            # extraConfigLua) -- the VS Code "overview ruler" equivalent.
            scrollview = {
              enable = true;
              settings = {
                signs_on_startup = [
                  "diagnostics"
                  "search"
                  "marks"
                ];
                # scrollview hides itself entirely whenever the whole buffer
                # already fits on screen (nothing to scroll to) -- which is
                # most short/example files, and would otherwise make it look
                # like the "where in the file are the errors/git changes"
                # overview isn't working at all.
                always_show = true;
              };
            };
            # A blazing fast and easy to configure neovim statusline written in lua.
            lualine.enable = true;
            # Snippet Engine for Neovim.
            luasnip.enable = true;

            lsp = {
              enable = true;
              inlayHints = true;
              servers = {
                bashls.enable = true;
                # Spellcheck
                harper_ls = {
                  enable = false;
                  settings.settings = {
                    "harper-ls" = {
                      linters = {
                        boring_words = true;
                        linking_verbs = true;
                        # Rarely useful with coding
                        sentence_capitalization = false;
                        spell_check = false;
                      };
                      codeActions = {
                        forceStable = true;
                      };
                    };
                  };
                };
                jsonls.enable = true;
                lua_ls = {
                  enable = true;
                  settings.telemetry.enable = false;
                };
                marksman.enable = true;
                nil_ls = {
                  enable = true;
                  settings = {
                    formatting.command = [ "nixpkgs-fmt" ];
                  };
                };
                pyright = {
                  enable = true;
                  settings = {
                    python = {
                      analysis = {
                        typeCheckingMode = "basic";
                        autoSearchPaths = true;
                        useLibraryCodeForTypes = true;
                        diagnosticMode = "workspace";
                      };
                    };
                  };
                };
                pylsp = {
                  enable = false;
                  settings.plugins = {
                    black.enabled = true;
                    flake8.enabled = false;
                    isort.enabled = true;
                    jedi.enabled = false;
                    mccabe.enabled = false;
                    pycodestyle.enabled = false;
                    pydocstyle.enabled = true;
                    pyflakes.enabled = false;
                    pylint.enabled = true;
                    rope.enabled = false;
                    yapf.enabled = false;
                  };
                };
                yamlls.enable = true;
                # Rust
                #
                # No cargo/rustc/rust-analyzer toolchain is installed
                # system-wide here on purpose: toolchains are provided
                # per-project via a flake devShell (rust-overlay) loaded by
                # direnv. `packageFallback = true` appends Nixvim's own
                # rust-analyzer to the *end* of PATH instead of the front, so
                # a project-provided rust-analyzer wins when present, while
                # this one still works as a fallback for stray .rs files
                # opened outside of a flake devShell.
                rust_analyzer = {
                  enable = true;
                  installCargo = false;
                  installRustc = false;
                  packageFallback = true;
                  # nvim-lspconfig's stock root_dir shells out to `rustc
                  # --print sysroot` unconditionally, and to `cargo metadata`
                  # whenever a Cargo.toml is found -- and if that `cargo`
                  # call fails (our stub rustc/cargo above always does, and a
                  # real one fails too whenever a project's toolchain isn't
                  # in the picture, e.g. before direnv has loaded), its
                  # on_dir() callback is simply never invoked, so the client
                  # never starts. No crash, no error, no diagnostics, no
                  # hover, nothing -- and it stays that way for the rest of
                  # the session even after a real toolchain becomes
                  # available. Replaced with a plain filesystem lookup that
                  # always resolves synchronously; rust-analyzer still does
                  # its own (isolated, non-crashing) cargo workspace
                  # resolution once it's actually running.
                  extraOptions.root_dir.__raw = ''
                    function(bufnr, on_dir)
                      local fname = vim.api.nvim_buf_get_name(bufnr)
                      on_dir(
                        vim.fs.root(fname, { "Cargo.toml", "rust-project.json" })
                          or vim.fs.dirname(vim.fs.find(".git", { path = fname, upward = true })[1])
                      )
                    end
                  '';
                };

                ts_ls.enable = true; # TS/JS
                cssls.enable = true; # CSS
                html.enable = true; # HTML
                dockerls.enable = true; # Docker
                markdown_oxide.enable = true; # Markdown
              };
            };

            # mini = {
            #  enable = true;
            #  modules = {
            #    animate = {
            #      enable = true;
            #    };
            #  };
            #};

            none-ls.sources.formatting.black.enable = true;
            snacks = {
              enable = true;
              settings = {
                image = {
                  enabled = true;
                  force = true;
                };
                picker = {
                  enabled = true;
                  hidden = true;
                };

                explorer = {
                  enabled = true;
                };

                lazygit = {
                  enabled = true;
                };
                notifier = {
                  enabled = true;
                };
                dashboard = {
                  enable = true;
                  preset = {
                    header = ''
                      ███████╗██████╗ ███████╗██████╗
                      ██╔════╝██╔══██╗██╔════╝██╔══██╗
                      █████╗  ██████╔╝█████╗  ██║  ██║
                      ██╔══╝  ██╔══██╗██╔══╝  ██║  ██║
                      ██║     ██║  ██║███████╗██████╔╝
                      ╚═╝     ╚═╝  ╚═╝╚══════╝╚═════╝
                    '';
                  };

                  sections = [
                    { section = "header"; }
                    {
                      icon = " ";
                      title = "Keymaps";
                      section = "keys";
                      indent = 2;
                      padding = 1;
                    }
                    {
                      icon = " ";
                      title = "Recent Files";
                      section = "recent_files";
                      indent = 2;
                      padding = 1;
                    }
                    {
                      icon = " ";
                      title = "Projects";
                      section = "projects";
                      indent = 2;
                      padding = 1;
                    }
                    {
                      icon = " ";
                      title = "Restore Session";
                      section = "keys";
                      indent = 2;
                      padding = 1;
                      action = ":SessionRestore";
                      key = "s";
                    }
                  ];
                };
              };
            };
            # telescope.enable = true;
            treesitter = {
              enable = true;
              folding.enable = false;
              settings.indent.enable = true;
            };
            web-devicons.enable = true;
            which-key = {
              enable = true;
              settings.preset = "helix";
            };

            inc-rename.enable = true;
            noice = {
              enable = true;
              settings = {
                presets = {
                  long_message_to_split = true;
                  command_palette = true;
                  inc_rename = true;
                };
              };
            };

            package-info = {
              enable = true;
            };

            # Automatic session management per working directory
            auto-session = {
              enable = true;
              settings = {
                auto_restore = true;
                auto_save = true;
                auto_create = true;
                lazy_support = false;
                show_auto_restore_notif = true;
                bypass_save_filetypes = [
                  "snacks_dashboard"
                  "snacks_layout_box"
                ];
                close_unsupported_windows = true;
                suppressed_dirs = [
                  "~/"
                  "~/Downloads"
                  "/tmp"
                ];
                # Keyed by directory only, not directory+branch: switching
                # branches outside nvim (or reviewing a PR/worktree) used to
                # leave no session for the new branch, surfacing as "Could
                # not restore session" on the next launch even though a
                # session for the directory did exist.
                git_use_branch_name = false;
                log_level = "info";
                pre_save_cmds = [
                  {
                    __raw = ''
                      function()
                        -- Close snacks explorer before saving session
                        for _, win in ipairs(vim.api.nvim_list_wins()) do
                          local buf = vim.api.nvim_win_get_buf(win)
                          local ft = vim.bo[buf].filetype
                          if ft == "snacks_layout_box" or ft == "snacks_picker_list" or ft == "snacks_explorer" then
                            pcall(vim.api.nvim_win_close, win, true)
                          end
                        end
                      end
                    '';
                  }
                ];
                post_restore_cmds = [
                  {
                    __raw = ''
                      function()
                        -- Reopen snacks explorer after restoring session
                        vim.schedule(function()
                          Snacks.explorer()
                        end)
                      end
                    '';
                  }
                ];
              };
            };
          };
          viAlias = true;
          vimAlias = true;
          vimdiffAlias = true;
        };
      }
    );
  };
}
