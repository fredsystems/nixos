# Cider 3 — Apple Music client distributed as an AppImage.
#
# Added as an overlay so pkgs.cider3 is available everywhere
# (systemPackages, home-manager, devShells) without any manual imports.
#
# Usage in overlays/default.nix:
#
#   final: prev: {
#     cider3 = final.callPackage ./cider.nix { };
#   }
{
  appimageTools,
  fetchurl,
  makeWrapper,
  ...
}:
let
  pname = "cider3";
  version = "3.1.8";

  src = fetchurl {
    # don't worry cider guys, the file is not normally there
    # I enable it when a system I maintain needs it
    url = "https://fredclausen.com/cider-v3.1.8-linux-x64.AppImage";
    sha256 = "sha256-s1CMYAfDULaEyO0jZguA2bA7D7ogqRR4v/LkMD+luKw=";
  };

  appimageContents = appimageTools.extract { inherit pname version src; };
in
appimageTools.wrapType2 {
  inherit pname version src;
  nativeBuildInputs = [ makeWrapper ];

  extraInstallCommands = ''
    install -m 444 -D ${appimageContents}/Cider.desktop \
      $out/share/applications/cider3.desktop

    substituteInPlace $out/share/applications/cider3.desktop \
      --replace-warn 'Exec=Cider %U' "Exec=$out/bin/${pname} %U" \
      --replace-warn 'Icon=cider' 'Icon=Cider'

    cp -r ${appimageContents}/usr/share/icons $out/share/icons

    wrapProgram $out/bin/${pname} \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations}}"
  '';
}
