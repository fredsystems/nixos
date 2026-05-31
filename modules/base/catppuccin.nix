{
  catppuccin = {
    enable = true;
    # Opt out of the new global auto-enroll behavior introduced in
    # catppuccin/nix #817. We keep per-port enables explicit across the
    # feature modules, so set this to `false` to preserve current behavior
    # and silence the "catppuccin/nix will soon auto enroll ports" warning.
    autoEnable = false;
    flavor = "mocha";
    accent = "lavender";
  };
}
