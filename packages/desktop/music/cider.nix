{
  pkgs,
  ...
}:
let
  pname = "cider3";
  extrapname = "cider";
  version = "3.1.8";

  src = pkgs.fetchurl {
    # don't worry cider guys, the file is not normally there
    # I enable it when a system I maintain needs it
    url = "https://fredclausen.com/cider-v3.1.8-linux-x64.AppImage";
    sha256 = "sha256-s1CMYAfDULaEyO0jZguA2bA7D7ogqRR4v/LkMD+luKw=";
  };
  appImageContents = pkgs.appimageTools.extract {
    inherit version src;
    pname = extrapname;
  };
in
pkgs.appimageTools.wrapType2 {
  inherit pname version src;
  inherit pkgs;
  nativeBuildInputs = [ pkgs.makeWrapper ];
  extraInstallCommands = ''
      wrapProgram $out/bin/${pname} \
       --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations}}" \
       --add-flags "--no-sandbox --disable-gpu-sandbox" # Cider 2 does not start up properly without these from my preliminary testing

    install -m 444 -D ${appImageContents}/Cider.desktop $out/share/applications/Cider.desktop
    # patch the .desktop file to use the right executable

    substituteInPlace $out/share/applications/Cider.desktop \
      --replace-warn 'Exec=Cider %U' 'Exec=cider3 %U'
    cp -r ${appImageContents}/usr/share/icons $out/share
  '';
}
