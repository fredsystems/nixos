{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.pythonVenvApps;

  # Idempotent venv bootstrap + dependency sync, run as ExecStartPre.
  # The venv itself lives inside the app's own (non-Nix-store) directory,
  # so it survives across nixos-rebuild / colmena deploys. Dependencies
  # are only reinstalled when requirements.txt actually changes, tracked
  # via a sha256 stamp file next to the venv.
  mkSetupScript =
    name: app:
    pkgs.writeShellScript "python-venv-setup-${name}" ''
      set -euo pipefail

      APP_DIR=${lib.escapeShellArg app.path}
      VENV_DIR="$APP_DIR/${app.venvDir}"
      REQ_FILE="$APP_DIR/${app.requirementsFile}"
      STAMP_FILE="$VENV_DIR/.requirements.sha256"

      if [ ! -d "$VENV_DIR" ]; then
        echo "pyapp-${name}: creating venv at $VENV_DIR"
        ${app.python.interpreter} -m venv "$VENV_DIR"
      fi

      if [ ! -f "$REQ_FILE" ]; then
        echo "pyapp-${name}: WARNING $REQ_FILE not found, skipping dependency sync" >&2
        exit 0
      fi

      NEW_HASH="$(${pkgs.coreutils}/bin/sha256sum "$REQ_FILE" | ${pkgs.coreutils}/bin/cut -d' ' -f1)"
      OLD_HASH="$(cat "$STAMP_FILE" 2>/dev/null || true)"

      if [ "$NEW_HASH" != "$OLD_HASH" ]; then
        echo "pyapp-${name}: requirements.txt changed, syncing venv"
        "$VENV_DIR/bin/pip" install --upgrade pip
        "$VENV_DIR/bin/pip" install -r "$REQ_FILE"
        echo "$NEW_HASH" > "$STAMP_FILE"
      fi
    '';

  mkService =
    name: app:
    lib.nameValuePair "pyapp-${name}" {
      inherit (app) enable after wants;
      description = "Python venv app: ${name}";
      wantedBy = [ "multi-user.target" ];

      environment = app.environment // {
        VENV = "${app.path}/${app.venvDir}";
        # manylinux wheels assume libstdc++/libgcc_s are just present on any
        # normal distro (unlike e.g. libpng, which auditwheel vendors into
        # the wheel itself) — NixOS has no FHS paths, so nothing provides
        # them unless pointed at explicitly. app.extraLibraryPaths lets a
        # host add more (e.g. gfortran's runtime for scipy).
        LD_LIBRARY_PATH = lib.makeLibraryPath app.extraLibraryPaths;

        # Point matplotlib at the systemd-managed CacheDirectory below.
        # Without this it tries $HOME/.cache, which ProtectHome=read-only
        # blocks, and silently rebuilds its font cache into a throwaway /tmp
        # directory on every single start.
        MPLCONFIGDIR = "/var/cache/pyapp-${name}";
      };

      serviceConfig = {
        Type = "simple";
        User = app.user;
        Group = app.group;
        WorkingDirectory = app.path;

        ExecStartPre = "${mkSetupScript name app}";
        # systemd applies its own $VAR/${VAR} substitution to the whole
        # ExecStart= line before bash ever sees it — regardless of quoting,
        # since systemd's quotes only affect argv splitting, not expansion
        # semantics. Escape literal `$` as `$$` so systemd passes a literal
        # `$` through untouched, letting bash (which inherits VENV via
        # `environment` below) do the actual expansion.
        ExecStart = "${pkgs.bash}/bin/bash -c ${
          lib.escapeShellArg (lib.replaceStrings [ "$" ] [ "$$" ] app.execStart)
        }";

        EnvironmentFile = lib.mkIf (app.environmentFile != null) app.environmentFile;

        Restart = "on-failure";
        RestartSec = "5s";

        # Sandboxing.
        #
        # These services run unvetted third-party code from PyPI, reachable
        # from the internet through nginx, so the blast radius of a bug in
        # the app or one of its pinned dependencies is worth bounding.
        #
        # BOTH ProtectSystem AND ProtectHome are required, and the reason is
        # not obvious. `ProtectSystem=strict` is documented as mounting "the
        # entire file system hierarchy" read-only, but /home is exempt in
        # practice -- verified on fredvps, where a service with
        # ProtectSystem=strict could still write freely to /home/nik and
        # /home/nik/.cache. Since these apps live entirely under $HOME, that
        # setting alone protects almost nothing that matters here.
        #
        # ProtectHome=read-only covers the gap. Not "tmpfs": that replaces
        # /home with an empty mount, and the unit then fails to start at all
        # with "Failed to set up mount namespacing: /home/nik/<app>: No such
        # file or directory", because ReadWritePaths cannot resolve a path
        # that no longer exists.
        #
        # ReadWritePaths then punches a hole for the app's own directory,
        # which is the only place either app writes:
        #
        #   * test-site   -- a 98 MB SQLite database at
        #                    app/database/discord_db.sqlite. Its two
        #                    plt.savefig() calls target BytesIO, not disk.
        #   * discord-bot -- 2085 PNGs written with RELATIVE filenames
        #                    (`plt.savefig(f"{name}.png")`), which resolve
        #                    against WorkingDirectory = app.path.
        #
        # Confirmed no writes land outside those directories.
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        ReadWritePaths = [ app.path ];

        # matplotlib needs a writable cache and defaults to $HOME/.cache,
        # which ProtectHome has just made read-only. It does not fail -- it
        # silently falls back to a fresh /tmp directory and rebuilds the font
        # cache on every start, which costs seconds of CPU per restart and
        # then throws the result away.
        #
        # CacheDirectory gives it somewhere real: systemd creates
        # /var/cache/<name> owned by the service user and it survives
        # restarts. MPLCONFIGDIR points matplotlib at it. Verified the cache
        # persists (fontlist-v330.json is written and reused).
        CacheDirectory = "pyapp-${name}";

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        LockPersonality = true;

        # Network access is the point of these services, so AF_INET stays.
        # AF_UNIX is needed for DNS resolution via nsswitch. Everything else
        # -- raw packet sockets, netlink, bluetooth -- has no business here.
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];

        # No @privileged / @obsolete syscalls. Deliberately not a tighter set:
        # CPython plus compiled manylinux wheels (numpy, scipy, matplotlib)
        # reach for a wide syscall surface, and an over-tight filter fails at
        # import time rather than obviously.
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@obsolete"
        ];
        SystemCallArchitectures = "native";
      };
    };
in
{
  options.services.pythonVenvApps = lib.mkOption {
    default = { };
    description = ''
      Python applications whose dependencies are deliberately *not*
      sourced from nixpkgs (e.g. unmaintained upstreams pinned to
      package versions far behind what nixpkgs ships). Each app gets
      its own venv, created on first start and kept in sync with its
      `requirements.txt` via plain `pip`, scoped entirely to the app's
      own directory — which lives outside the Nix store (typically a
      manually `git clone`d checkout). Nix only manages the systemd
      unit and the interpreter used to create the venv; every
      dependency is resolved straight from PyPI at service-start time.
    '';
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether to generate the systemd unit for this app.";
          };

          path = lib.mkOption {
            type = lib.types.path;
            description = ''
              Absolute path to the app's checkout (e.g. /home/nik/test_site).
              Must already exist — Nix does not manage its contents.
            '';
          };

          user = lib.mkOption {
            type = lib.types.str;
            description = "System user the service runs as, and that owns `path`.";
          };

          group = lib.mkOption {
            type = lib.types.str;
            default = "users";
            description = "System group the service runs as.";
          };

          python = lib.mkOption {
            type = lib.types.package;
            default = pkgs.python3;
            description = ''
              Interpreter used only to create the venv (`python -m venv`).
              Pin this per-app when a pinned dependency has no wheel for
              the default interpreter's ABI — e.g. scipy==1.10.1 has no
              cp312+ wheel, matplotlib==3.7.5 has no cp313 wheel.
            '';
          };

          venvDir = lib.mkOption {
            type = lib.types.str;
            default = ".venv";
            description = "Venv directory name, relative to `path`.";
          };

          requirementsFile = lib.mkOption {
            type = lib.types.str;
            default = "requirements.txt";
            description = "Requirements file name, relative to `path`.";
          };

          extraLibraryPaths = lib.mkOption {
            type = lib.types.listOf lib.types.package;
            default = [ pkgs.stdenv.cc.cc.lib ];
            description = ''
              Packages whose `lib` output is joined into `LD_LIBRARY_PATH`
              for the service, so compiled C-extension wheels (scipy,
              matplotlib, Pillow, etc.) can find runtime shared libraries
              that manylinux assumes are just present on a normal distro
              (libstdc++.so.6, libgcc_s.so.1 — provided by the default)
              but that don't exist anywhere on NixOS's FHS-less
              filesystem otherwise. Add more per-app as needed, e.g.
              `pkgs.gfortran.cc.lib` for scipy's libgfortran/libquadmath.
            '';
          };

          execStart = lib.mkOption {
            type = lib.types.str;
            description = ''
              Shell command used to start the app. Reference the venv
              via the `$VENV` environment variable, e.g.
              `"$VENV/bin/uvicorn app.main:app --host 0.0.0.0 --port 8078"`.
            '';
          };

          environment = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Extra environment variables for the service.";
          };

          environmentFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Optional EnvironmentFile= (e.g. a sops secret) for the service.";
          };

          after = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "network-online.target" ];
            description = "systemd `After=` units.";
          };

          wants = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "network-online.target" ];
            description = "systemd `Wants=` units.";
          };
        };
      }
    );
  };

  config.systemd.services = lib.listToAttrs (lib.mapAttrsToList mkService cfg);
}
