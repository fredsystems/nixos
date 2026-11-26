# Task Manager TMOG (https://www.tmog.org/) -- Dave Plummer's Qt 6 task
# manager. Closed source and not in nixpkgs; upstream publishes only an
# AppImage, a .deb and a .tar.gz.
#
# Built from the .tar.gz rather than wrapping the AppImage: the binary links
# only the public Qt 6 API (symbol versions Qt_6 / Qt_6.4, no private Qt),
# libstdc++ and glibc >= 2.35, so autoPatchelf against nixpkgs' Qt gives a
# 10 MB native package that uses nixpkgs' Wayland plugin and theming instead
# of a 40 MB bundled Qt in an FHS sandbox.
#
# Only the task manager itself is installed. The tarball's tmog-screensaver
# and tmog-register-screensaver are XScreenSaver integration, which nothing
# on this fleet runs.
#
# Things the free edition reads that NixOS does not provide by default, all
# degrading to "unavailable" rather than failing (see
# https://www.tmog.org/linux.html):
#   * CPU package power (/sys/class/powercap/*/energy_uj, root-only since
#     5.10 because it is a side channel)
#   * SMBIOS memory facts (/sys/firmware/dmi/tables/DMI, root-only)
#   * PCI/GPU names from hardcoded /usr/share/{hwdata,misc}/pci.ids paths
#
# The license forbids public redistribution, so this is `unfree` (not
# redistributable) and only ever fetched from tmog.org. Upstream keeps old
# versioned artifacts online, so a pinned URL keeps working after a release.
#
# The pin lives in tmog.json; scripts/update-tmog.sh rewrites it from
# upstream's release manifest and update-tmog.yaml runs that daily. Turn off
# "Check for Updates on App Start" in TMOG's settings -- Nix owns the version.
#
# Usage in overlays/default.nix:
#   tmog = final.callPackage ./tmog.nix { };
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  qt6,
}:
let
  pin = lib.importJSON ./tmog.json;
in
stdenv.mkDerivation {
  pname = "tmog";
  inherit (pin) version;

  src = fetchurl {
    inherit (pin) url hash;
  };

  nativeBuildInputs = [
    autoPatchelfHook
    qt6.wrapQtAppsHook
  ];

  buildInputs = [
    qt6.qtbase
    qt6.qtsvg
    qt6.qtwayland
    stdenv.cc.cc.lib
  ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 bin/tmog-task-manager -t $out/bin
    install -Dm644 share/applications/com.tmog.taskmanager.desktop -t $out/share/applications
    install -Dm644 share/metainfo/com.tmog.taskmanager.metainfo.xml -t $out/share/metainfo
    install -Dm644 share/man/man1/tmog-task-manager.1.gz -t $out/share/man/man1
    cp -r share/icons share/pixmaps $out/share/
    install -Dm644 share/doc/tmog/* -t $out/share/doc/tmog

    runHook postInstall
  '';

  meta = {
    description = "Native system monitor and task manager by the author of Windows Task Manager";
    homepage = "https://www.tmog.org/";
    changelog = "https://www.tmog.org/release-notes.html";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "tmog-task-manager";
  };
}
