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

  # FIXME(nixpkgs-open-webui-mcp2): WORKAROUND, not a fix.
  #
  # The mcp 1.29 -> 2.2 bump (https://github.com/NixOS/nixpkgs/pull/575004)
  # broke open-webui 0.12.3 at runtime: open_webui/utils/mcp/client.py
  # imports `streamablehttp_client`, which mcp 2 removed, so the service
  # crash-loops on startup (the build and pythonImportsCheck still pass).
  # It also marks posthog (a transitive dep via chromadb) broken, since
  # posthog's meta.broken is `versionAtLeast mcp.version "2"`.
  #
  # Pin mcp back to nixpkgs' `mcp_1` inside open-webui's own python set,
  # the same thing nixpkgs does for music-assistant. That fixes both the
  # import and posthog in one move.
  #
  # Built from the package's own python3Packages (`override` with a
  # function), so it applies equally to `pkgs.open-webui` and fredhub's
  # `unstablePkgs.open-webui`. Gated on mcp actually being >= 2, so it is
  # a no-op on pins where it is not.
  #
  # Revert: once nixpkgs' open-webui works against mcp 2 (or pins mcp_1
  # itself), delete this block and use cfg.openwebPackage directly in
  # ExecStart. See .github/workflows/track-upstream-fixes.yaml.
  openwebPackage =
    let
      pkg = cfg.openwebPackage;
    in
    if (pkg.override.__functionArgs or { }) ? python3Packages then
      pkg.override (prev: {
        python3Packages = prev.python3Packages.overrideScope (
          pyFinal: pyPrev: {
            mcp =
              if lib.versionAtLeast pyPrev.mcp.version "2" && pyPrev ? mcp_1 then pyFinal.mcp_1 else pyPrev.mcp;
          }
        );
      })
    else
      pkg;
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

    openwebPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.open-webui;
      description = "Open Web UI package to use";
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
    nixpkgsUnfree.allowed = [ "open-webui" ];

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
            ExecStart = "${openwebPackage}/bin/open-webui serve --host ${cfg.host} --port ${toString cfg.webuiPort}";

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
