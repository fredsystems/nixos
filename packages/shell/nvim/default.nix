{ user, ... }:
let
  username = user;
in
{
  config = {
    home-manager.users.${username} =
      {
        pkgs,
        ...
      }:
      {
        # install ripgrep via pkgs

        home.packages = with pkgs; [
          ripgrep
        ];

        programs.nixvim = {
          defaultEditor = true;
          enable = true;

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

                        local function ensure_normal_buffer()
                          -- Don't interfere while Neovim is exiting
                          if vim.v.exiting ~= vim.NIL and vim.v.exiting ~= 0 then
                            return
                          end

                          vim.schedule(function()
                            if not has_normal_buffer() then
                              vim.cmd("enew")
                            end
                          end)
                        end

                        vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
                          callback = ensure_normal_buffer,
                        })
                        vim.api.nvim_create_user_command("Qa", "qa", {})

            vim.diagnostic.config({ virtual_lines = true })
            vim.diagnostic.config({ virtual_text = true })
            vim.api.nvim_create_autocmd({ "CursorHold" }, {
                pattern = "*",
                callback = function()
                    for _, winid in pairs(vim.api.nvim_tabpage_list_wins(0)) do
                        if vim.api.nvim_win_get_config(winid).zindex then
                            return
                        end
                    end
                    vim.diagnostic.open_float({
                        scope = "cursor",
                        focusable = false,
                        close_events = {
                            "CursorMoved",
                            "CursorMovedI",
                            "BufHidden",
                            "InsertCharPre",
                            "WinLeave",
                        },
                    })
                end
            })

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
              action = "<cmd>bnext<CR>";
              key = "<leader>bn";
              options.desc = "Next buffer";
            }
            {
              action = "<cmd>bprevious<CR>";
              key = "<leader>bp";
              options.desc = "Previous buffer";
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
          ];

          opts = {
            updatetime = 100;
            number = true;
            relativenumber = true;
            shiftwidth = 2;
            swapfile = false;
            undofile = true;
            incsearch = true;
            inccommand = "split";
            ignorecase = true;
            smartcase = true;
            signcolumn = "yes:1";
          };

          plugins = {
            bufferline = {
              enable = true;

              settings = {
                options = {
                  separator_style = "thin";
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
                sources = {
                  default = [
                    "lsp"
                    "buffer"
                    "path"
                    "snippets"
                    "copilot"
                    "emoji"
                    "spell"
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
                    spell = {
                      name = "Spell";
                      module = "blink-cmp-spell";
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
            blink-cmp-spell.enable = true;
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
                  enable = true;
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
                rust_analyzer = {
                  enable = true;
                  installCargo = false;
                  installRustc = false;
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
                      icon = " ";
                      title = "Keymaps";
                      section = "keys";
                      indent = 2;
                      padding = 1;
                    }
                    {
                      icon = " ";
                      title = "Recent Files";
                      section = "recent_files";
                      indent = 2;
                      padding = 1;
                    }
                    {
                      icon = " ";
                      title = "Projects";
                      section = "projects";
                      indent = 2;
                      padding = 1;
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
          };
          viAlias = true;
          vimAlias = true;
          vimdiffAlias = true;
        };
      };
  };
}
