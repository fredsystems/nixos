{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.desktop.airframes;
  allUsers = config.shared.allUsers;
  inherit (pkgs.stdenv.hostPlatform) isLinux;
in
{
  options.desktop.airframes = {
    enable = lib.mkEnableOption "Airframes.io desktop app";
  };

  config = lib.mkIf cfg.enable {
    nixpkgsUnfree.allowed = [ "airframes-desktop" ];

    # From the airframes-desktop flake's overlay, which both builders apply.
    # System-wide so nix-darwin links the .app into /Applications/Nix Apps.
    environment.systemPackages = [ pkgs.airframes-desktop ];

    # Browser sign-in returns to the app through an airframes:// link. The app
    # tries to register itself as that handler at startup, but mimeapps.list is
    # Home Manager's, so the association has to be declared here.
    home-manager.users = lib.mkIf isLinux (
      lib.genAttrs allUsers (_: {
        xdg.mimeApps = {
          associations.added."x-scheme-handler/airframes" = [ "Airframes.desktop" ];
          defaultApplications."x-scheme-handler/airframes" = [ "Airframes.desktop" ];
        };
      })
    );
  };
}
