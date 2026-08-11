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
  # then convert to SRI:
  #   nix hash convert --hash-algo sha256 --to sri <base32>
  installer = pkgs.fetchurl {
    url = "https://download.garmin.com/omt/express/GarminExpress.exe";
    hash = "sha256-3R9B5WFN+24kohZgZetLnvO50UQODPPJPjDIzd4A7WE=";
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

        # Garmin Express is a WPF app hosting CefSharp. Under Wine its WPF
        # (Avalon / "MIL") hardware render path produces an all-black window
        # -- the app is running and laying out text, it just composites
        # nothing visible. Forcing WPF to its software renderer is the fix.
        #
        # Note this is NOT the same thing as the CEF `--disable-gpu` flags
        # below: those only affect the embedded Chromium panes, and were
        # verified (present in /proc/<pid>/cmdline) to leave the window black
        # on their own. `DwmAttachMilContent` in the Wine log is the tell
        # that the black surface belongs to WPF, not CEF.
        echo "==> Phase 3/4: Forcing WPF software rendering..." >&2
        wine reg add 'HKCU\Software\Microsoft\Avalon.Graphics' \
          /v DisableHWAcceleration /t REG_DWORD /d 1 /f
        wineserver -w

        echo "==> Phase 4/4: Running Garmin Express installer..." >&2
        wine ${installer}

        # The installer launches Express itself as a detached process that is
        # NOT our child, and that process keeps wineserver alive. A blocking
        # `wineserver -w` here would therefore hang forever and never reach
        # the marker write below, causing the whole 20-minute .NET install to
        # be repeated on the next launch. Kill the prefix instead: it ends
        # the installer's Express as well, so the only instance that ever
        # runs is the one we launch ourselves (with the flags applied).
        wineserver -k || true

        if [ -f "$EXE" ]; then
          touch "$MARKER"
        else
          echo "==> Installer finished but express.exe is missing." >&2
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

      # Garmin Express embeds CefSharp (Chromium). These flags only affect the
      # embedded browser panes -- the black-window fix is the WPF
      # DisableHWAcceleration registry key set during first-run setup above.
      # Kept because software rendering for the CEF panes is consistent with
      # forcing it for WPF, and costs nothing on a page-based UI.
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

    # Deliberately NO host-side MTP stack here (no simple-mtpfs, no libmtp,
    # and gvfs is not force-enabled). MTP allows exactly one initiator at a
    # time: whichever process opens the session owns the device until it
    # closes it. A host MTP client browsing the Garmin therefore locks Wine
    # out of it entirely. Since the whole point of this module is to let
    # Garmin Express talk to the device, host MTP tooling is an active
    # liability rather than a convenience. Desktops that want to browse a
    # Garmin as a filesystem get that from the desktop environment's own
    # gvfs, which is enabled elsewhere.
    users.users = lib.genAttrs allUsers (_: {
      packages = [
        garmin-express
        desktopItem
        pkgs.wineWow64Packages.stable
        pkgs.winetricks
      ];
    });
  };
}
