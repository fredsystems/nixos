{
  lib,
  pkgs,
  config,
  user,
  ...
}:
with lib;
let
  username = user;
  cfg = config.desktop.zed;
in
{
  options.desktop.zed = {
    enable = mkOption {
      description = "Enable Zed.";
      default = false;
    };
  };

  config = mkIf cfg.enable {
    sops.secrets.openai_api = {
      owner = config.users.users.${username}.name;
    };

    home-manager.users.${username} = {
      # install packages
      home.packages = with pkgs; [
        (pkgs.writeShellScriptBin "zed" ''
          set -a
          source ${config.sops.secrets.openai_api.path}
          set +a
          exec ${pkgs.zed-editor}/bin/zeditor "$@"
        '')
        vtsls
        # custom wrapper that feels bad but makes lsp work
        (pkgs.writeShellScriptBin "vtsls-local" ''
          exec ${lib.getExe pkgs.vtsls} --stdio
        '')
        ruff
        (pkgs.writeShellScriptBin "ruff-local" ''
          exec ${lib.getExe pkgs.ruff} server
        '')
        shellcheck
        bash-language-server
        (pkgs.writeShellScriptBin "bash-language-server-local" ''
          exec ${lib.getExe pkgs.bash-language-server} start
        '')
        shfmt
        dockerfile-language-server
        (pkgs.writeShellScriptBin "dockerfile-language-server-local" ''
          exec ${lib.getExe pkgs.dockerfile-language-server} --stdio
        '')
        ansible-lint
        crates-lsp
        vscode-json-languageserver
        (pkgs.writeShellScriptBin "jsonls-local" ''
          exec ${lib.getExe pkgs.vscode-json-languageserver} --stdio
        '')
        package-version-server
        lua-language-server
      ];
      catppuccin.zed = {
        enable = true;
        icons.enable = true;
        italics = true;
      };
      programs.zed-editor = {
        enable = true;
        extensions = [
          "nix"
          "toml"
          "tombi"
          "rust"
          "python"
          "markdown"
          "yaml"
          "basher"
          "dockerfile"
          "scss"
          "lua"
          "ini"
          "ansible"
          "crates-lsp"
          "json"
          "json5"
          "css"
          "markdown"
          "markdownlint"
          "git-firefly"
          "xml"
          "just"
        ];
        mutableUserSettings = false;
        userSettings = {
          journal = {
            hour_format = "hour24";
          };

          show_edit_predictions = true;
          features = {
            edit_prediction_provider = "copilot";
          };

          load_direnv = "shell_hook";
          base_keymap = "VSCode";
          show_whitespaces = "all";
          ui_font_size = 14;
          buffer_font_size = 14;

          ##########################################################################
          # AI / Agent configuration (THIS IS THE ONLY VALID AI TOP-LEVEL KEY)
          ##########################################################################
          agent = {
            always_allow_tool_actions = true;

            default_model = {
              provider = "copilot_chat";
              model = "gpt-4o";
            };

            inline_alternatives = [
              {
                provider = "copilot_chat";
                model = "gpt-4o";
              }
              {
                provider = "ollama";
                model = "qwen2.5-coder:7b";
              }
              {
                provider = "ollama";
                model = "deepseek-coder-v2:latest";
              }
              {
                provider = "zed.dev";
                model = "claude-3-5-sonnet-latest";
              }
            ];
          };

          ##########################################################################
          # Language model backends
          ##########################################################################
          language_models = {
            ollama = {
              api_url = "http://fredhub.local:11434";

              available_models = [
                {
                  name = "qwen3-coder";
                  display_name = "Qwen 3 Coder (FredHub)";
                  max_tokens = 100000;
                  supports_tools = true;
                  supports_thinking = false;
                  supports_images = false;
                }
                {
                  name = "qwen2.5-coder:7b";
                  display_name = "Qwen 2.5 Coder (FredHub)";
                  max_tokens = 32000;
                  supports_tools = true;
                  supports_thinking = false;
                  supports_images = false;
                }
                {
                  name = "deepseek-coder-v2:latest";
                  display_name = "DeepSeek Coder V2 (FredHub)";
                  max_tokens = 128000;
                  supports_tools = true;
                  supports_thinking = false;
                  supports_images = false;
                }
              ];
            };
          };

          ##########################################################################
          # File type overrides
          ##########################################################################
          file_types = {
            Ansible = [
              "**/modules/ansible/plays/*.yaml"
            ];
          };

          ##########################################################################
          # Node (used by LSPs and extensions)
          ##########################################################################
          node = {
            path = "${lib.getExe pkgs.nodejs}";
            npm_path = "${lib.getExe' pkgs.nodejs "npm"}";
          };

          ##########################################################################
          # Terminal
          ##########################################################################
          terminal = {
            alternate_scroll = "off";
            blinking = "off";
            copy_on_select = false;
            dock = "bottom";

            detect_venv = {
              on = {
                directories = [
                  ".env"
                  "env"
                  ".venv"
                  "venv"
                ];
                activate_script = "default";
              };
            };

            env = {
              TERM = "wezterm";
            };

            font_family = "Fira Code";
            font_features = null;
            font_size = null;
            line_height = "comfortable";
            option_as_meta = false;
            button = false;
            shell = "system";

            toolbar = {
              breadcrumbs = true;
            };

            working_directory = "current_project_directory";
          };

          ##########################################################################
          # Language formatting
          ##########################################################################
          languages = {
            CSS = {
              tab_size = 2;
              formatter = "prettier";
            };
            SCSS = {
              tab_size = 2;
              formatter = "prettier";
            };
            JSON = {
              tab_size = 2;
              formatter = "prettier";
            };
            YAML = {
              tab_size = 2;
            };
            Markdown = {
              tab_size = 2;
            };
            Python = {
              language_servers = [
                "!ruff"
                "pyright"
              ];
            };

            Nix = {
              language_servers = [
                "nixd"
                "!nil"
              ];
            };

            # Bash = {
            #   language_servers = [ "bash-language-server" ];
            # };
          };

          ##########################################################################
          # LSP configuration
          ##########################################################################
          lsp = {
            rust-analyzer = {
              binary = {
                path = "${lib.getExe pkgs.rust-analyzer}";
              };

              initialization_options = {
                check = {
                  command = "clippy";
                };
              };

              settings = {
                # check = {
                #   command = "clippy";

                #   # Zed only supports `features` OR `--all-features`, not both
                #   features = null;

                #   # Everything else must go here
                #   extraArgs = [
                #     "--all-targets"
                #     "--all-features"
                #     "--"
                #     "-D"
                #     "warnings"
                #   ];
                # };

                cargo.buildScripts.enable = true;

                diagnostics = {
                  enable = true;
                  styleLints.enable = true;
                };

                procMacro.enable = true;
                rustc.source = "discover";
              };
            };

            crates-lsp = {
              binary.path = "${lib.getExe pkgs.crates-lsp}";
            };

            nixd.binary.path = "${lib.getExe pkgs.nixd}";

            vtsls = {
              binary.path = "/etc/profiles/per-user/fred/bin/vtsls-local";
            };

            ruff = {
              binary.path = "/etc/profiles/per-user/fred/bin/ruff-local";
            };

            bash-language-server.binary.path = "/etc/profiles/per-user/fred/bin/bash-language-server-local";

            shellcheck.binary.path = "${lib.getExe pkgs.shellcheck}";
            shfmt.binary.path = "${lib.getExe pkgs.shfmt}";

            dockerfile-language-server.binary.path = "/etc/profiles/per-user/fred/bin/dockerfile-language-server-local";

            markdownlint.settings = {
              MD013 = false;
              MD033 = false;
              MD060 = false;
            };
          };
        };
      };
    };
  };
}
