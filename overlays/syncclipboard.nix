# SyncClipboard desktop client — distributed as an AppImage.
#
# Added as an overlay so pkgs.syncclipboard is available everywhere
# (systemPackages, home-manager, devShells) without any manual imports.
#
# Upstream ships AppImage/deb/rpm only and is not in nixpkgs, so this wraps
# the AppImage rather than building from source. It is an Avalonia (.NET) app
# and shows its UI through a StatusNotifierItem tray icon; wayle provides the
# SNI watcher on this fleet, so the tray works without extra plumbing.
#
# Usage in overlays/default.nix:
#
#   final: prev: {
#     syncclipboard = final.callPackage ./syncclipboard.nix { };
#   }
{
  appimageTools,
  fetchurl,
  icu,
  wl-clipboard,
  xclip,
  ...
}:
let
  pname = "syncclipboard";
  version = "3.2.0";

  src = fetchurl {
    url = "https://github.com/Jeric-X/SyncClipboard/releases/download/v${version}/SyncClipboard_linux_x64.AppImage";
    hash = "sha256-dqdxO094da47A5S3ZNZhbimBY8MO3sqsgE0/42LC1H0=";
  };

  appimageContents = appimageTools.extract { inherit pname version src; };
in
appimageTools.wrapType2 {
  inherit pname version src;

  # icu: .NET aborts at startup without it, printing
  #
  #   Couldn't find a valid ICU package installed on the system. Please
  #   install libicu ... Alternatively you can set the configuration flag
  #   System.Globalization.Invariant to true
  #
  # Providing the real library is preferable to invariant globalization,
  # which would silently change string comparison and formatting behaviour.
  #
  # wl-clipboard and xclip are how the client actually reads the clipboard --
  # it shells out to them rather than doing it in-process. Upstream's own AUR
  # package lists both as runtime `depends`, but an AppImage declares nothing,
  # so inside this FHS sandbox they were simply absent.
  #
  # That absence did not fail loudly. The client silently fell back to
  # Avalonia's in-process X11 path, which reaches the Wayland selection only
  # through XWayland: it caught some copies and returned empty for others,
  # which then classified as `Unkown` and skipped the upload with no error.
  # The result looked like flaky syncing rather than a missing dependency.
  #
  # Installing these is necessary but not sufficient -- the client still has
  # to be told to prefer them over the X11 path. See the ProhibitSources
  # setting in features/desktop/clipboard.
  extraPkgs = _: [
    icu
    wl-clipboard
    xclip
  ];

  extraInstallCommands = ''
    install -m 444 -D ${appimageContents}/xyz.jericx.desktop.syncclipboard.desktop \
      $out/share/applications/${pname}.desktop

    substituteInPlace $out/share/applications/${pname}.desktop \
      --replace-warn 'Exec=/usr/bin/SyncClipboard.Desktop.Default' "Exec=$out/bin/${pname}" \
      --replace-warn 'TryExec=/usr/bin/SyncClipboard.Desktop.Default' "TryExec=$out/bin/${pname}"

    cp -r ${appimageContents}/usr/share/icons $out/share/icons
  '';
}
