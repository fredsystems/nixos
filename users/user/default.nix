{
  pkgs,
  user,
  verbose_name,
  ...
}:
let
  username = user;
  full_name = verbose_name;
in
{
  imports = [
    ../../hardware-profiles
  ];

  config = {
    # Enable RTL-SDR hardware profile
    hardware-profile.rtl-sdr.enable = true;

    users.users.${username} = {
      linger = true;
      isNormalUser = true;
      description = "${full_name}";
      extraGroups = [
        "networkmanager"
        "wheel"
        "docker"
        "wireshark"
      ];

      packages = with pkgs; [
        gh
        stow
        rtl-sdr-librtlsdr
        rrdtool
        # dconf2nix don't want but for now we'll leave it commented out. Useful to dump dconf settings to nix, but the nix package is old and broke
      ];
    };
  };
}
