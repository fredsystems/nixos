{
  lib,
  pkgs,
  config,
  isDarwin,
  ...
}:
let
  cfg = config.ai.local-llm;
  isLinux = !isDarwin;
in
{
  options.ai.local-llm = {
    enable = lib.mkEnableOption "local LLM stack (Ollama + Open WebUI)";

    ollamaPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.ollama-rocm;
      description = "Ollama package to use (rocm by default, override for CPU).";
    };

    ollamaPort = lib.mkOption {
      type = lib.types.port;
      default = 11434;
      description = "Port for Ollama API";
    };

    webuiPort = lib.mkOption {
      type = lib.types.port;
      default = 8889;
      description = "Port for Open WebUI";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Bind address for services";
    };

    models = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "qwen3-coder"
        "qwen2.5-coder:7b"
      ];
      description = ''
        Models to pull at boot and keep updated on a weekly schedule.
        Passed to services.ollama.loadModels and also checked for
        updates by a periodic systemd timer.
      '';
    };
  };

  imports = lib.optional isLinux ./linux.nix;

  config = lib.mkIf cfg.enable {
    ########################################
    # REQUIRED: group must exist
    ########################################
    users.groups.ollama = { };

    ########################################
    # Ollama (AMD ROCm)
    ########################################
    services.ollama = {
      enable = true;

      package = cfg.ollamaPackage;

      inherit (cfg) host;
      port = cfg.ollamaPort;

      loadModels = cfg.models;

      environmentVariables = {
        OLLAMA_CONTEXT_LENGTH = "4096";
        OLLAMA_KEEP_ALIVE = "5m";
      };
    };

    ########################################
    # Periodic model update checker
    ########################################
    systemd = {
      timers.ollama-model-updater = lib.mkIf (cfg.models != [ ]) {
        description = "Weekly ollama model update check";
        wantedBy = [ "timers.target" ];

        timerConfig = {
          OnCalendar = "weekly";
          Persistent = true;
          RandomizedDelaySec = "6h";
        };
      };

      ########################################
      # Open WebUI
      ########################################
      services = {
        ollama-model-updater = lib.mkIf (cfg.models != [ ]) {
          description = "Check for ollama model updates";
          after = [ "ollama.service" ];
          requires = [ "ollama.service" ];

          serviceConfig = {
            Type = "oneshot";
            DynamicUser = true;
          };

          environment = {
            HOME = "/var/lib/ollama";
            OLLAMA_HOST = "${cfg.host}:${toString cfg.ollamaPort}";
            OLLAMA_MODELS = "/var/lib/ollama/models";
          };

          script = ''
            ${lib.concatMapStringsSep "\n" (model: ''
              echo "Updating ${model}..."
              ${lib.getExe cfg.ollamaPackage} pull ${lib.escapeShellArg model}
            '') cfg.models}
          '';
        };

        open-webui = {
          description = "Open WebUI (UI for Ollama)";
          wantedBy = [ "multi-user.target" ];
          after = [
            "network.target"
            "ollama.service"
          ];
          requires = [ "ollama.service" ];

          serviceConfig = {
            ExecStart = "${pkgs.open-webui}/bin/open-webui serve --host ${cfg.host} --port ${toString cfg.webuiPort}";

            Restart = "always";
            RestartSec = 3;

            StateDirectory = "open-webui";
            WorkingDirectory = "/var/lib/open-webui";

            Environment = [
              "OLLAMA_BASE_URL=http://${cfg.host}:${toString cfg.ollamaPort}"

              "WEBUI_AUTH=false"
              "ENABLE_SIGNUP=false"

              # Writable dirs (critical on NixOS)
              "DATA_DIR=/var/lib/open-webui"
              "STATIC_DIR=/var/lib/open-webui/static"

              "HOST=${cfg.host}"
              "PORT=${toString cfg.webuiPort}"
            ];

            LimitNOFILE = 1048576;
          };
        };
      };
    };

    users.users.ollama = {
      isSystemUser = true;
      home = "/var/lib/ollama";
      createHome = true;
      group = "ollama";
    };

    ########################################
    # System requirements
    ########################################
    #hardware.graphics.enable = true;

    environment.systemPackages = [
      cfg.ollamaPackage
      # pkgs.open-webui
    ];
  };
}
