{
  lib,
  pkgs,
  config,
  user,
  extraUsers ? [ ],
  ...
}:
let
  cfg = config.desktop.print;
  allUsers = [ user ] ++ extraUsers;

  # FIXME(vicinae-468-printer-icon): system-config-printer's .desktop ships
  # `Icon=printer`, a bare freedesktop icon name. Vicinae (our launcher,
  # features/desktop/environments/modules/vicinae) fails to resolve this
  # *specific* icon name via QIcon::fromTheme, rendering a "?" placeholder,
  # even though the exact same theme resolves every other icon we've tested
  # (including other printing-related ones like `cups`) and a standalone
  # QIcon::fromTheme("printer") call succeeds outside of vicinae. This is a
  # confirmed upstream vicinae bug, not a theme/config issue -- see
  # https://github.com/vicinaehq/vicinae/discussions/468 (multiple reporters
  # hit the exact same "only the printer icon" symptom, unresolved as of Oct
  # 2025). No fix commit/version has landed yet, so this isn't registered in
  # .github/tracked-upstream-fixes.json (none of the four check types have a
  # concrete target); revisit once upstream identifies a fix.
  #
  # Workaround: point Icon= at an absolute path to the printer icon
  # system-config-printer already bundles internally, bypassing
  # icon-theme-name resolution (and the bug) entirely.
  system-config-printer-iconfix = pkgs.system-config-printer.overrideAttrs (oldAttrs: {
    postInstall = (oldAttrs.postInstall or "") + ''
      substituteInPlace $out/share/applications/system-config-printer.desktop \
        --replace-fail "Icon=printer" \
          "Icon=$out/share/system-config-printer/icons/i-network-printer.png"
    '';
  });
in
{
  options.desktop.print = {
    enable = lib.mkEnableOption "printing services";
  };

  config = lib.mkIf cfg.enable {
    # Enable CUPS to print documents.
    services = {
      printing.enable = true;

      avahi = {
        enable = true;
        nssmdns4 = true;
        openFirewall = true;
      };
    };

    # Equivalent to `programs.system-config-printer.enable = true`, but with
    # `system-config-printer-iconfix` (see FIXME above) instead of the
    # plain package, since that option doesn't expose a `.package` override.
    services.system-config-printer.enable = true;
    environment.systemPackages = [ system-config-printer-iconfix ];

    # Add users to the "lp" group so they can add/remove printers via
    # system-config-printer without a polkit password prompt each time.
    users.users = lib.genAttrs allUsers (_: {
      extraGroups = [ "lp" ];
    });
  };
}
