# Unfree-package allowlist -- single source of truth for the whole fleet.
#
# WHY THIS EXISTS
#
# The fleet used to set `nixpkgs.config.allowUnfree = true` unconditionally
# (features/common/system/default.nix for Linux, profiles/darwin.nix for
# Darwin). That allows every unfree package everywhere, on every host,
# forever -- including on eight servers that install no unfree software at
# all. There was no record of what was actually wanted.
#
# Two narrow `allowUnfreePredicate` definitions existed alongside it
# (features/desktop/fonts, hosts/linux/fredhub) and looked like enforcement.
# They were not. nixpkgs' real rule, from
# pkgs/stdenv/generic/check-meta.nix:
#
#   hasDeniedUnfreeLicense = attrs:
#     hasUnfreeLicense attrs && !allowUnfree && !allowUnfreePredicate attrs;
#
# That is an OR, not a precedence rule: a package is permitted if
# `allowUnfree` is true OR the predicate returns true. With `allowUnfree =
# true` the predicate is never consulted for a decision, so those two lists
# were dead weight -- redundant rather than overridden. (Note also that
# check-meta.nix defaults the predicate to `x: false`, not to `allowUnfree`.)
#
# WHY AN OPTION AND NOT JUST A PREDICATE
#
# `allowUnfreePredicate` is a FUNCTION. The module system cannot merge two
# function definitions, so the moment a second module wants to permit one
# more package you get a conflict -- and the only reason that had not
# happened yet is that the fonts predicate and the fredhub predicate never
# applied to the same host. Exposing a LIST option instead means every
# module contributes with ordinary list merging, and exactly one place turns
# the merged list into the predicate.
#
# Adding a package here is a deliberate act: it should be something actually
# installed and used, named as `lib.getName` sees it (usually the pname).
{ config, lib, ... }:
{
  options.nixpkgsUnfree.allowed = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "vscode" ];
    description = ''
      Unfree package names permitted on this host, as matched by
      `lib.getName`. Contributions from every module are merged, so a
      feature module may append the unfree packages it needs without
      knowing what any other module requires.

      This replaces a fleet-wide `allowUnfree = true`. A package not listed
      here fails evaluation with nixpkgs' own unfree error, which names the
      package -- add it here if it is genuinely wanted.
    '';
  };

  config = {
    # Fleet-wide allowlist.
    #
    # Discovered empirically: the blanket `allowUnfree = true` was removed and
    # every host evaluated until it passed, reading the wanted name out of
    # nixpkgs' own remediation hint (which prints the `lib.getName` value --
    # NOT the derivation name, which differs for anything whose pname does,
    # e.g. vimplugin-zellij.nvim-0-unstable-... vs pname zellij.nvim).
    #
    # Everything here is software already installed and in use; none of it was
    # added to make an error go away. See AUDIT-2026-08-04.md item 5.1.
    #
    # Only zellij.nvim is genuinely fleet-wide (it lives inside the neovim
    # wrapper and reaches every host, bare servers included). Every other
    # approved package is contributed by the module that actually pulls it
    # in -- features/desktop/steam for steam*, features/ai/lammacpp for
    # open-webui, the desktop app modules for the rest, modules/hardware/
    # fingerprint.nix for the fingerprint driver.
    nixpkgsUnfree.allowed = [
      # neovim config, every host including bare servers
      "zellij.nvim"
    ];

    # The single place the merged allowlist becomes nixpkgs' predicate.
    nixpkgs.config.allowUnfreePredicate =
      pkg: builtins.elem (lib.getName pkg) config.nixpkgsUnfree.allowed;
  };
}
