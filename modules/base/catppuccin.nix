{ lib, options, ... }:
{
  catppuccin = {
    enable = true;
    flavor = "mocha";
    accent = "lavender";
  }
  # `autoEnable` was introduced in catppuccin/nix #817 (post-25.11). The
  # release-25.11 input used by server hosts does not have this option yet,
  # so guard the assignment on its presence. Setting it to `false` preserves
  # current behavior (per-port enables stay explicit in feature modules)
  # and silences the "catppuccin/nix will soon auto enroll ports" warning
  # on hosts pinned to unstable.
  // lib.optionalAttrs (options.catppuccin ? autoEnable) {
    autoEnable = true;
  };
}
