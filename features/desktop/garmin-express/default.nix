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
  cfg = config.desktop.garmin-express;

  # Pinned Garmin Express installer.
  # Garmin's URL is unversioned ("latest"); when they rotate the binary the
  # build will fail until the hash is refreshed. Refresh with:
  #   nix-prefetch-url https://download.garmin.com/omt/express/GarminExpress.exe
  installer = pkgs.fetchurl {
    url = "https://download.garmin.com/omt/express/GarminExpress.exe";
    sha256 = "10d7bdxlwcgkgzygb2pr1r68i6wkwpvfnjzg6hwqzk1j9j32xf5r";
  };

  garmin-express = pkgs.writeShellApplication {
    name = "garmin-express";
    runtimeInputs = with pkgs; [
      wineWow64Packages.stable
      winetricks
      coreutils
    ];
    # Keep the installer reachable for first-run setup.
    text = ''
      export WINEPREFIX="''${XDG_DATA_HOME:-$HOME/.local/share}/wineprefixes/garmin-express"
      export WINEARCH=win64
      # Block Wine's Mono so real .NET can be installed by winetricks.
      # Also disable winemenubuilder so Wine doesn't export its own duplicate
      # .desktop entries / file associations into ~/.local/share/applications.
      export WINEDLLOVERRIDES="mscoree=,mshtml=,winemenubuilder.exe="
      # Garmin Express is 32-bit; installs under "Program Files (x86)".
      EXE="$WINEPREFIX/drive_c/Program Files (x86)/Garmin/Express/express.exe"
      MARKER="$WINEPREFIX/.garmin-express-installed"

      if [ ! -f "$MARKER" ]; then
        echo "==> First-run setup for Garmin Express. This will take 10-20 minutes." >&2
        echo "==> Phase 1/3: Initialising Wine prefix..." >&2
        mkdir -p "$WINEPREFIX"
        wineboot --init
        wineserver -w

        echo "==> Phase 2/3: Installing .NET Framework 4.8 (downloads from Microsoft)..." >&2
        # corefonts helps with installer rendering; dotnet48 is the runtime.
        winetricks -q --force corefonts dotnet48
        wineserver -w

        echo "==> Phase 3/3: Running Garmin Express installer..." >&2
        wine ${installer}
        wineserver -w

        if [ -f "$EXE" ]; then
          touch "$MARKER"
        fi
      fi

      if [ ! -f "$EXE" ]; then
        echo "Garmin Express was not installed to the expected path:" >&2
        echo "  $EXE" >&2
        echo "" >&2
        echo "To retry the installer manually:" >&2
        echo "  WINEPREFIX=\"$WINEPREFIX\" wine ${installer}" >&2
        echo "" >&2
        echo "To wipe state and start over:" >&2
        echo "  rm -rf \"$WINEPREFIX\"" >&2
        exit 1
      fi

      # Garmin Express embeds CefSharp (Chromium). Under XWayland with GPU
      # acceleration it renders as a black window. Disable GPU accel for the
      # embedded browser process.
      exec wine "$EXE" --disable-gpu --disable-gpu-compositing "$@"
    '';
  };

  desktopItem = pkgs.makeDesktopItem {
    name = "garmin-express";
    desktopName = "Garmin Express";
    exec = "garmin-express";
    icon = "wine";
    categories = [
      "Utility"
      "Network"
    ];
    comment = "Update maps and software for Garmin devices";
  };
in
{
  options.desktop.garmin-express = {
    enable = lib.mkEnableOption "Garmin Express (Windows app via Wine)";
  };

  config = lib.mkIf cfg.enable {
    # Allow user-level access to Garmin USB devices (vendor 0x091e).
    services.udev.extraRules = ''
      SUBSYSTEM=="usb", ATTRS{idVendor}=="091e", MODE="0666", GROUP="users"
    '';

    # MTP/auto-mount support for Garmin devices that present as storage.
    services.gvfs.enable = true;

    users.users = lib.genAttrs allUsers (_: {
      packages = with pkgs; [
        garmin-express
        desktopItem
        wineWow64Packages.stable
        winetricks
        jmtpfs
        libmtp
      ];
    });
  };
}
