{
  lib,
  config,
  ...
}:
let
  cfg = config.desktop.flatpak;
in
{
  options.desktop.flatpak = {
    enable = lib.mkEnableOption "Flatpak";
  };

  config = lib.mkIf cfg.enable {
    services.flatpak = {
      enable = true;

      packages = [
        "com.sublimehq.SublimeText"
      ];

      update = {
        onActivation = true;
        auto = {
          enable = true;
          onCalendar = "weekly";
        };
      };
    };

    # NOTE: nix-flatpak reuses nixpkgs' native `services.flatpak.enable`
    # option, so nixpkgs' own services/desktops/flatpak.nix module fires
    # alongside nix-flatpak's. That native module already appends
    # `$HOME/.local/share/flatpak/exports` and `/var/lib/flatpak/exports`
    # to `environment.profiles`, and NixOS's default
    # `environment.profileRelativeSessionVariables.XDG_DATA_DIRS = [ "/share" ]`
    # automatically derives the correctly-suffixed XDG_DATA_DIRS entries
    # from every profile — including these two. Manually adding
    # `environment.sessionVariables.XDG_DATA_DIRS` here would just
    # duplicate those same two entries in the final PATH-like string, so
    # it's deliberately omitted. Verified via:
    #   nix eval .#nixosConfigurations.Daytona.config.environment.profiles
  };
}
