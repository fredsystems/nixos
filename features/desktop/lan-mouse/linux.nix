# Linux-only half of ./default.nix: the systemd restart policy (Home
# Manager's `systemd.user.services` does not exist on Darwin) and the NixOS
# firewall hole (`networking.firewall` does not exist on nix-darwin either).
# Imported only by features/desktop/default.nix (Linux); the Darwin callers
# of ./default.nix do not import this file.
{
  lib,
  config,
  ...
}:
let
  cfg = config.desktop.lan-mouse;
  allUsers = config.shared.allUsers;
in
{
  config = lib.mkIf cfg.enable {
    home-manager.users = lib.genAttrs allUsers (_: {
      # Upstream's unit sets only Type and ExecStart, so a crash leaves
      # input sharing dead until the next login with no indication beyond
      # the pointer refusing to cross the edge. These merge into their
      # definition rather than replacing it -- no keys overlap. Matches what
      # features/desktop/clipboard does for the same reason.
      #
      # Ordering is handled separately: their `Install.WantedBy` is
      # `hyprland-session.target`, and maranello's home.nix additionally
      # restarts the unit from `hl.on("hyprland.start")`, which is what
      # guarantees the layer-shell capture surfaces are created against
      # outputs that actually exist.
      systemd.user.services.lan-mouse.Service = {
        Restart = "always";
        RestartSec = "5s";
      };
    });

    # UDP, not TCP: lan-mouse carries input events over DTLS.
    networking.firewall.allowedUDPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
