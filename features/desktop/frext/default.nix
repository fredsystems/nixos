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
  cfg = config.desktop.frext;
  inherit (pkgs.stdenv) isLinux;
in
{
  options.desktop.frext = {
    enable = lib.mkEnableOption "frext text editor";
  };

  config = lib.mkIf cfg.enable {
    home-manager.users = lib.genAttrs allUsers (_: {
      programs.frext = {
        enable = true;
      };

      xdg = lib.mkIf isLinux {
        mimeApps = {
          associations.added = {
            "text/plain" = [ "frext.desktop" ];
            "application/x-zerosize" = [ "frext.desktop" ];
          };

          defaultApplications = {
            "text/plain" = [ "frext.desktop" ];
            "application/x-zerosize" = [ "frext.desktop" ];
          };
        };
      };
    });
  };
}
