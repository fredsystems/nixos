{
  lib,
  pkgs,
  config,
  ...
}:
let
  allUsers = config.shared.allUsers;
  cfg = config.desktop.frext;
  inherit (pkgs.stdenv.hostPlatform) isLinux;
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
