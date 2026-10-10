{
  pkgs,
  user,
  extraUsers ? [ ],
  lib,
  catppuccinInput,
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;

  # FIXME(catppuccin-lazygit-65-author-colors): WORKAROUND, not a fix.
  # lazygit 0.66.0 moved `gui.authorColors` to `gui.theme.authorColors` and
  # refuses to start when a config file still uses the old key and cannot be
  # migrated in place (our theme file lives read-only in /nix/store). The
  # catppuccin/nix port pin (`pkgs/sources.json`) still points at
  # catppuccin/lazygit 798ad2e (v2.3.0), which uses the old key. The fix is
  # https://github.com/catppuccin/lazygit/pull/65 (commit f50a723), merged but
  # not yet picked up by catppuccin/nix's "update port sources" bot.
  #
  # Delete this binding and the `catppuccin.sources.lazygit` override below
  # once our locked `catppuccin` input's sources.json pins a catppuccin/lazygit
  # rev containing f50a723. Tracked by
  # .github/workflows/track-upstream-fixes.yaml.
  fixedLazygitTheme = (import "${catppuccinInput}" { inherit pkgs; }).packages.lazygit.overrideAttrs {
    version = "0-unstable-2026-10-09";
    src = pkgs.fetchFromGitHub {
      owner = "catppuccin";
      repo = "lazygit";
      rev = "f50a723711ccb524691652cd870c94415aaa4669";
      hash = "sha256-hb6W9WwBOtsq+TFw72P17BQCMtHJ3y0um2rSiXOzVZ8=";
    };
  };
in
{
  config = {
    home-manager.users = lib.genAttrs allUsers (
      _:
      { config, ... }:
      {
        home.packages = with pkgs; [
          gmp
        ];

        programs.lazygit = {
          enable = true;
          settings = {
            gui = {
              nerdFontsVersion = "3";
            };
          };
        };

        catppuccin = {
          lazygit.enable = true;

          # Only lazygit >= 0.66 rejects the old key, so hosts still on an
          # older lazygit (the stable-channel servers) keep the upstream pin
          # and their closures stay untouched.
          sources = lib.mkIf (lib.versionAtLeast config.programs.lazygit.package.version "0.66") {
            lazygit = fixedLazygitTheme;
          };
        };
      }
    );
  };
}
