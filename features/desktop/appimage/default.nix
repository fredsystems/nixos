{
  lib,
  pkgs,
  config,
  user,
  extraUsers ? [ ],
  ...
}:
let
  cfg = config.desktop.appimage;
  allUsers = [ user ] ++ extraUsers;
in
{
  options.desktop.appimage = {
    enable = lib.mkEnableOption "AppImage";
  };

  config = lib.mkIf cfg.enable {
    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        appimage-run
        # FIXME(nixpkgs-549694-dwarfs-gcc): see
        # .github/tracked-upstream-fixes.json. gearlever pulls dwarfs 0.14.0,
        # whose bundled folly-lite copy no longer compiles (std::memset used
        # without <cstring>, which the current GCC rejects). AppImage support
        # itself is unaffected -- appimage-run and the binfmt registration
        # below are what provide it; gearlever is only a GUI manager.
        # gearlever
      ];
    });

    boot.binfmt.registrations.appimage = {
      wrapInterpreterInShell = false;
      interpreter = "${pkgs.appimage-run}/bin/appimage-run";
      recognitionType = "magic";
      offset = 0;
      mask = ''\xff\xff\xff\xff\x00\x00\x00\x00\xff\xff\xff'';
      magicOrExtension = ''\x7fELF....AI\x02'';
    };
  };
}
