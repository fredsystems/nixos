{ lib, options, ... }:
let
  channelGates = import ../lib/channel-gates.nix;
in
{
  catppuccin = {
    enable = true;
    flavor = "mocha";
    accent = "mauve";
  }
  # `autoEnable` was introduced in catppuccin/nix #817. The stable catppuccin
  # input used by server hosts does not have it yet, so guard the assignment
  # on its presence (channel gate `catppuccin-auto-enable-nixos`,
  # modules/lib/channel-gates.nix). Enabling it lets catppuccin enrol every
  # port it supports and silences the "catppuccin/nix will soon auto enroll
  # ports" warning on hosts pinned to unstable.
  // lib.optionalAttrs (channelGates.available "catppuccin-auto-enable-nixos" options) {
    autoEnable = true;
  };
}
