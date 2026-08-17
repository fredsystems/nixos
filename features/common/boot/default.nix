{
  boot = {
    # ── Bootloader ─────────────────────────────────────────────────────────────
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;

      # Every host's /boot is a small VFAT ESP (confirmed on nvrhub), and
      # none use grub. Left uncapped, systemd-boot keeps a kernel+initrd set
      # for every generation ever built, and colmena deploys frequently
      # enough (every push that touches an impacted host) that the ESP
      # fills up and the NEXT deploy fails to write its boot entry -- the
      # classic "cannot write to /boot: No space left on device" that
      # leaves a host stuck one generation short of booting at all. 10 is
      # enough rollback depth to survive a bad deploy discovered a few
      # pushes later while keeping the ESP's worst case bounded.
      systemd-boot.configurationLimit = 10;
    };

    # ── Plymouth (graphical splash) ────────────────────────────────────────────
    plymouth = {
      enable = true;
    };

    consoleLogLevel = 0;
    initrd.verbose = false;
    kernelParams = [
      "quiet"
      "splash"
      "boot.shell_on_fail"
      "loglevel=3"
      "rd.systemd.show_status=false"
      "rd.udev.log_level=3"
      "udev.log_priority=3"
    ];
    # Hide the OS choice for bootloaders.
    # It's still possible to open the bootloader list by pressing any key
    # It will just not appear on screen unless a key is pressed
    # loader.timeout = 0;
    #
  };

  catppuccin.grub.enable = true;
}
