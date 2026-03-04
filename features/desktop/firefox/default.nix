{
  lib,
  config,
  user,
  extraUsers ? [ ],
  ...
}:
with lib;
let
  username = user;
  cfg = config.desktop.firefox;
  allUsers = [ username ] ++ extraUsers;
in
{
  options.desktop.firefox = {
    enable = mkOption {
      description = "Install Firefox browser.";
      default = false;
    };
  };

  config = mkIf cfg.enable {
    # Install firefox.
    programs.firefox.enable = true;

    home-manager.users = lib.genAttrs allUsers (_: {
      xdg = {
        mimeApps = {
          associations.added = {
            "text/html" = [ "firefox.desktop" ];
            "x-scheme-handler/http" = [ "firefox.desktop" ];
            "x-scheme-handler/https" = [ "firefox.desktop" ];
            "x-scheme-handler/about" = [ "firefox.desktop" ];
            "x-scheme-handler/unknown" = [ "firefox.desktop" ];
          };

          defaultApplications = {
            "text/html" = [ "firefox.desktop" ];
            "x-scheme-handler/http" = [ "firefox.desktop" ];
            "x-scheme-handler/https" = [ "firefox.desktop" ];
            "x-scheme-handler/about" = [ "firefox.desktop" ];
            "x-scheme-handler/unknown" = [ "firefox.desktop" ];
          };
        };
      };
    });
  };
}
