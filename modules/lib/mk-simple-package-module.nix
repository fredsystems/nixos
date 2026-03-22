# mkSimplePackageModule: Creates a NixOS module that gates package installation
# behind an enable option. Eliminates boilerplate for modules that only install
# packages with no additional configuration.
#
# Per-user packages (default):
#
#   import ../../../modules/lib/mk-simple-package-module.nix {
#     optionPath = "desktop.vlc";
#     description = "VLC";
#     packages = pkgs: [ pkgs.vlc ];
#   }
#
# System-wide packages:
#
#   import ../../../modules/lib/mk-simple-package-module.nix {
#     optionPath = "desktop.libreoffice";
#     description = "LibreOffice";
#     packages = pkgs: with pkgs; [ libreoffice-qt hunspell hunspellDicts.en_US ];
#     systemWide = true;
#   }
{
  optionPath,
  description,
  packages,
  systemWide ? false,
}:
if systemWide then
  {
    lib,
    pkgs,
    config,
    ...
  }:
  let
    path = lib.splitString "." optionPath;
    cfg = lib.getAttrFromPath path config;
  in
  {
    options = lib.setAttrByPath path {
      enable = lib.mkEnableOption description;
    };

    config = lib.mkIf cfg.enable {
      environment.systemPackages = packages pkgs;
    };
  }
else
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
    path = lib.splitString "." optionPath;
    cfg = lib.getAttrFromPath path config;
  in
  {
    options = lib.setAttrByPath path {
      enable = lib.mkEnableOption description;
    };

    config = lib.mkIf cfg.enable {
      users.users = lib.genAttrs allUsers (_: {
        packages = packages pkgs;
      });
    };
  }
