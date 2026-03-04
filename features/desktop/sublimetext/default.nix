{
  lib,
  pkgs,
  config,
  user,
  extraUsers ? [ ],
  ...
}:
with lib;
let
  allUsers = [ user ] ++ extraUsers;
  cfg = config.desktop.sublimetext;
in
{
  options.desktop.sublimetext = {
    enable = mkOption {
      description = "Enable Sublime Text.";
      default = false;
    };
  };

  config = mkIf cfg.enable {
    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        sublime4
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
