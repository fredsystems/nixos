{
  lib,
  pkgs,
  config,
  user,
  extraUsers ? [ ],
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;
  cfg = config.desktop.sublimetext;
in
{
  options.desktop.sublimetext = {
    enable = lib.mkEnableOption "Sublime Text";
  };

  config = lib.mkIf cfg.enable {
    # Use the 4205 "dev" build rather than stable `sublime4` (4200). nixpkgs
    # marks 4200 as `broken` (its plugin host links insecure OpenSSL) and
    # refuses to evaluate it; 4205 carries the fix and is not broken. We do NOT
    # suppress that `broken` flag -- we move to the fixed build instead.
    #
    # 4205 still emits a `removal` (Python 3.3 drop) notice via `meta.problems`.
    # That notice surfacing as an eval *warning* (which our CI treats as fatal)
    # is a known nixpkgs bug -- see NixOS/nixpkgs#523712: `meta.problems`
    # spuriously fails eval CI. Scope a handler to ignore only that one spurious
    # `removal` notice, not the (already-resolved) security `broken` flag.
    nixpkgs.config.problems.handlers.sublimetext4.removal = "ignore";

    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        sublime4-dev
      ];
    });

    home-manager.users = lib.genAttrs allUsers (_: {
      xdg = {
        mimeApps = {
          associations.added = {
            "text/plain" = [ "sublime_text.desktop" ];
            "application/x-zerosize" = [ "sublime_text.desktop" ];
          };

          defaultApplications = {
            "text/plain" = [ "sublime_text.desktop" ];
            "application/x-zerosize" = [ "sublime_text.desktop" ];
          };
        };
      };
    });
  };
}
