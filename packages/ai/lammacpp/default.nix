{
  lib,
  pkgs,
  config,
  system,
  ...
}:
with lib;
let
  cfg = config.ai.local-llm;
  isDarwin = lib.hasSuffix "darwin" system;
  isLinux = !isDarwin;
in
{
  options.ai.local-llm = {
    enable = mkEnableOption "Enable local LLM stack (Ollama + Open WebUI)";

    ollamaPackage = mkOption {
      type = types.package;
      default = pkgs.ollama-rocm;
      description = "Ollama package to use (rocm by default, override for CPU).";
    };

    ollamaPort = mkOption {
      type = types.port;
      default = 11434;
      description = "Port for Ollama API";
    };

    webuiPort = mkOption {
      type = types.port;
      default = 8080;
      description = "Port for Open WebUI";
    };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Bind address for services";
    };
  };

  imports = lib.optional isLinux ./linux.nix;

  config = mkIf cfg.enable {
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

      environmentVariables = {
        OLLAMA_CONTEXT_LENGTH = "4096";
        OLLAMA_KEEP_ALIVE = "5m";
      };
    };

    ########################################
    # Open WebUI
    ########################################
    systemd.services.open-webui = {
      description = "Open WebUI (UI for Ollama)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "ollama.service"
      ];
      requires = [ "ollama.service" ];

      serviceConfig = {
        ExecStart = "${pkgs.open-webui}/bin/open-webui serve";

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
