# FIXME: mime types
import ../../../modules/lib/mk-simple-package-module.nix {
  optionPath = "desktop.libreoffice";
  description = "LibreOffice";
  packages =
    pkgs:
    with pkgs;
    let
      # The libreoffice wrapper only discovers hunspell/hyphen dictionaries by
      # scanning $NIX_PROFILES at runtime. That variable is exported by
      # /etc/set-environment for interactive shells but is NOT present in the
      # systemd graphical/D-Bus session, so dictionaries silently vanish when
      # LibreOffice is launched from the app launcher. Bake DICPATH into the
      # wrapper at build time so it works regardless of how it is started.
      hunspellDictionaries = [ hunspellDicts.en_US-large ];
      hyphenDictionaries = [ hyphenDicts.en_US ];
      dictionaries = hunspellDictionaries ++ hyphenDictionaries;
      dicPath = lib.concatStringsSep ":" (
        map (d: "${d}/share/hunspell") hunspellDictionaries
        ++ map (d: "${d}/share/hyphen") hyphenDictionaries
      );
      libreoffice = libreoffice-qt.override {
        extraMakeWrapperArgs = [
          "--prefix"
          "DICPATH"
          ":"
          dicPath
        ];
      };
    in
    [
      libreoffice
      hunspell
    ]
    ++ dictionaries;

  systemWide = true;
}
