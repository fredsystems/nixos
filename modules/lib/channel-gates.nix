# modules/lib/channel-gates.nix
#
# Registry of channel gates: places where one module has to emit different
# config depending on whether the host's nixpkgs / home-manager / catppuccin
# declares an option. They exist because servers track the stable release
# while desktops track unstable, so between two stable releases the fleet
# straddles every option rename that landed on unstable in the meantime.
#
# Every such gate goes through `available` below, by id, rather than an
# inline `options ? ...`:
#
#   hasStructuredSettings = channelGates.available "journald-settings" options;
#
# That makes each gate a tracked object instead of a comment, and the
# `channel-gates` flake check (flake/dev/checks.nix) enforces it:
#
#   * removeAt: the stable release that makes the gate obsolete, i.e. the
#     first release whose stable channel declares the option. Once the
#     locked nixpkgs-stable reaches it, the check FAILS until the gate's
#     fallback branch and its registry entry are deleted, so the release
#     bump PR cannot merge with dead compatibility code still in it.
#   * liveness: on the current pins the option must be missing on a stable
#     host and present on an unstable one. A gate present on both is
#     already dead (a backport, or a wrong removeAt); one missing on both is
#     wrong outright (unstable renamed it again). Either fails the check.
#   * references: every id must still be referenced outside this file, and
#     no `options ? ...` presence test may appear in a module outside it.
#
# `tree` names which option set the path is looked up in: "nixos" for the
# NixOS module system, "home-manager" for a home-manager user's options.
# Gate on the option's presence, never on a release string: presence is what
# the module actually depends on, and it flips by itself when stable moves.
#
# Pure data plus a builtins-only helper, imported by relative path (like
# ./home-dir.nix), so modules need no extra module argument to use it.
let
  gates = {
    # nixpkgs replaced the freeform services.journald.extraConfig string with
    # the structured services.journald.settings.Journal attrset, and made
    # extraConfig a removed option. Read by modules/base/journald.nix (which
    # writes it) and modules/monitoring/agent/node_exporter.nix (which reads
    # SystemMaxUse back out of it).
    journald-settings = {
      tree = "nixos";
      option = [
        "services"
        "journald"
        "settings"
      ];
      removeAt = "26.11";
    };

    # nixpkgs replaced services.avahi.publish.* with freeform
    # services.avahi.settings; the old names emit evaluation warnings.
    # features/common/system/default.nix.
    avahi-settings = {
      tree = "nixos";
      option = [
        "services"
        "avahi"
        "settings"
      ];
      removeAt = "26.11";
    };

    # home-manager added programs.nushell.loadSessionVariables with a
    # stateVersion-dependent default that warns until set explicitly.
    # features/shell/nushell/default.nix.
    nushell-load-session-variables = {
      tree = "home-manager";
      option = [
        "programs"
        "nushell"
        "loadSessionVariables"
      ];
      removeAt = "26.11";
    };

    # catppuccin/nix #817 added catppuccin.autoEnable, NixOS side.
    # modules/base/catppuccin.nix.
    catppuccin-auto-enable-nixos = {
      tree = "nixos";
      option = [
        "catppuccin"
        "autoEnable"
      ];
      removeAt = "26.11";
    };

    # The same catppuccin/nix #817 option, home-manager side.
    # modules/base/home.nix.
    catppuccin-auto-enable-home = {
      tree = "home-manager";
      option = [
        "catppuccin"
        "autoEnable"
      ];
      removeAt = "26.11";
    };
  };

  # `options ? a.b.c` over a path held in a list. Tolerates missing
  # intermediates, exactly as the `?` operator does.
  hasPath =
    path: set:
    path == [ ]
    || (
      builtins.isAttrs set
      && set ? ${builtins.head path}
      && hasPath (builtins.tail path) set.${builtins.head path}
    );

  gate =
    id:
    gates.${id}
      or (throw "channel-gates: unknown gate `${id}`. Register it in modules/lib/channel-gates.nix.");
in
{
  inherit gates hasPath;

  # Whether the option behind gate `id` is declared in `options`, which must
  # be the option set of the gate's tree (a NixOS module's `options`, or a
  # home-manager module's `options`).
  available = id: options: hasPath (gate id).option options;
}
