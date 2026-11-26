# Declarative onboarding, integrations, areas, devices and entities for Home
# Assistant.
#
# configuration.yaml covers automations, scripts, helpers and dashboards, but
# Home Assistant keeps the rest in .storage: the owner account, config entries
# for UI-only integrations (mqtt, zwave_js, frigate, ...), the area registry,
# and the device and entity registries that decide entity IDs. Hand-editing
# .storage is not an option, because the schema is internal and Home Assistant
# rewrites those files while it runs.
#
# This module runs ./reconcile.py after Home Assistant starts. It applies the
# tables below through the same REST and websocket APIs the frontend uses, and
# changes nothing when they already hold. See
# agent-docs/plans/PLAN_06_HOME_ASSISTANT.md, "Home Assistant's configuration
# is declarative".
#
# What it owns, and what it leaves alone:
#
#   onboarding     completed once, creating the owner from `owner`.
#   integrations   one config entry per declared integration. A declared
#                  domain is owned outright: other entries of it are removed.
#                  Changing an integration's steps removes and recreates its
#                  entry; changing only its options reruns the options flow.
#                  With pruneIntegrations, entries of undeclared domains are
#                  removed too, except keepDomains.
#   areas          created from `areas`; with pruneAreas, others are removed.
#   devices        only the declared ones are touched, and only the fields
#                  that are not null.
#
# It logs in as the owner on every run and revokes that session at the end, so
# no long-lived token exists. The password therefore has to keep matching the
# account; change it in sops and in the UI together.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.home-assistant-reconciler;
  hass = config.services.home-assistant;

  json = pkgs.formats.json { };

  entityModule = {
    options = {
      domain = lib.mkOption {
        type = lib.types.str;
        example = "light";
        description = "Entity domain, the part of the entity ID before the dot.";
      };

      originalName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Pick the entity whose integration-given name is this, when the
          device has several in `domain`. Without this or `uniqueId`, the one
          entity in `domain` that is not a config or diagnostic entity is used.
        '';
      };

      uniqueId = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Pick the entity with this registry unique ID.";
      };

      entityId = lib.mkOption {
        type = lib.types.strMatching "[a-z_]+\\.[a-z0-9_]+";
        example = "light.kitchen";
        description = "Entity ID to give it. Automations refer to this.";
      };

      name = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Display name. Null leaves the name alone.";
      };
    };
  };

  deviceModule = {
    options = {
      identifier = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        example = [
          "zwave_js"
          "3579141642-16"
        ];
        description = ''
          One of the device's registry identifiers, as `[ domain id ]`. For
          Z-Wave JS this is `[ "zwave_js" "<home id in decimal>-<node id>" ]`.
        '';
      };

      name = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Device name. Null leaves the name alone.";
      };

      area = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Name of a declared area. Null leaves the area alone.";
      };

      entities = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule entityModule);
        default = [ ];
        description = "The device's entities to name.";
      };
    };
  };

  integrationModule =
    { name, ... }:
    {
      options = {
        domain = lib.mkOption {
          type = lib.types.str;
          default = name;
          defaultText = lib.literalExpression "<name>";
          description = "Integration domain, e.g. `mqtt` or `zwave_js`.";
        };

        steps = lib.mkOption {
          type = lib.types.attrsOf json.type;
          default = { };
          description = ''
            Answers to the integration's config flow, keyed by step ID. A form
            step takes an attrset of field values; a menu step takes the ID of
            the option to choose. `{ _secret = "<name>"; }` anywhere in a value
            is replaced by the credential of that name from `secrets`.

            A step that is not declared fails the run with the fields it asks
            for, which is how to find out what a flow needs.
          '';
        };

        optionsFlow = lib.mkOption {
          type = lib.types.attrsOf json.type;
          default = { };
          description = "Answers to the integration's options flow, like `steps`.";
        };
      };
    };

  declaration = json.generate "home-assistant-reconciler.json" {
    url = "http://127.0.0.1:${toString hass.config.http.server_port}";
    stateFile = "${hass.configDir}/.nix-reconciler-state.json";
    inherit (cfg)
      startTimeout
      deviceTimeout
      areas
      pruneAreas
      pruneIntegrations
      keepDomains
      backup
      ;
    owner = {
      inherit (cfg.owner) name username language;
      password._secret = "owner-password";
    };
    integrations = lib.mapAttrs (_: i: {
      inherit (i) domain steps;
      options = i.optionsFlow;
    }) cfg.integrations;
    devices = map (d: {
      inherit (d) identifier name area;
      entities = map (e: {
        inherit (e)
          domain
          originalName
          uniqueId
          entityId
          name
          ;
      }) d.entities;
    }) cfg.devices;
  };

  reconcile = pkgs.writers.writePython3Bin "home-assistant-reconcile" {
    libraries = [ pkgs.python3Packages.aiohttp ];
    flakeIgnore = [
      "E501"
      "W503"
    ];
  } (builtins.readFile ./reconcile.py);
in
{
  options.services.home-assistant-reconciler = {
    enable = lib.mkEnableOption "applying declared onboarding, integrations and registry entries to Home Assistant";

    owner = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "The owner's display name.";
      };

      username = lib.mkOption {
        type = lib.types.str;
        description = "The owner's login name.";
      };

      passwordFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          File holding the owner's password, e.g. a sops secret. Read through
          LoadCredential, so it may be root-only. Used to create the owner at
          onboarding and to log in on every later run.
        '';
      };

      language = lib.mkOption {
        type = lib.types.str;
        default = "en";
        description = "The owner's language.";
      };
    };

    secrets = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      example = lib.literalExpression ''{ mqtt-password = config.sops.secrets."mqtt".path; }'';
      description = ''
        Files referenced from integration steps as `{ _secret = "<name>"; }`.
        Read through LoadCredential, so they may be root-only.
      '';
    };

    integrations = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule integrationModule);
      default = { };
      description = "Integrations to configure, one config entry each.";
    };

    pruneIntegrations = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Remove config entries of domains that are neither declared nor in
        `keepDomains`.
      '';
    };

    keepDomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "mobile_app" ];
      description = ''
        Domains whose entries are never pruned. `mobile_app` entries are
        created by the companion app when a phone registers, so they cannot
        be declared.
      '';
    };

    areas = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Area names.";
    };

    pruneAreas = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Remove areas that are not declared, such as onboarding's defaults.";
    };

    devices = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule deviceModule);
      default = [ ];
      description = "Devices to name and place, and their entities.";
    };

    backup = lib.mkOption {
      type = lib.types.nullOr json.type;
      default = null;
      description = ''
        Arguments to the `backup/config/update` websocket command, applied
        when the current backup settings differ. Null leaves them alone.
      '';
    };

    startTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = "Seconds to wait for Home Assistant, and for entries to load.";
    };

    deviceTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
      description = ''
        Seconds to wait for declared devices to appear in the registry.
        Devices still missing after that are skipped with a warning, so an
        unplugged switch does not fail a deploy.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = hass.enable;
        message = "services.home-assistant-reconciler needs services.home-assistant.enable.";
      }
    ];

    systemd.services.home-assistant-reconciler = {
      description = "Apply declared Home Assistant configuration";
      after = [ "home-assistant.service" ];
      requires = [ "home-assistant.service" ];
      partOf = [ "home-assistant.service" ];
      wantedBy = [ "home-assistant.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${lib.getExe reconcile} ${declaration}";
        User = "hass";
        Group = "hass";
        LoadCredential = [
          "owner-password:${cfg.owner.passwordFile}"
        ]
        ++ lib.mapAttrsToList (name: path: "${name}:${path}") cfg.secrets;

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ hass.configDir ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
      };
    };
  };
}
