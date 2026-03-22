{
  lib,
  config,
  ...
}:
let
  cfg = config.desktop.firefox;
in
{
  options.desktop.firefox = {
    enable = lib.mkEnableOption "Firefox browser";
  };

  # MIME associations for Firefox are in environments/modules/xdg-mime-common.nix
  # which is imported by all desktop environments (Hyprland, Niri, GNOME).
  config = lib.mkIf cfg.enable {
    programs.firefox.enable = true;
  };
}
