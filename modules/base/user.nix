{
  pkgs,
  lib,
  user,
  extraUsers ? [ ],
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

  config = lib.mkMerge [
    {
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
        ];
      };
    }

    (lib.mkIf (extraUsers != [ ]) {
      users.users = lib.genAttrs extraUsers (_: {
        linger = true;
        isNormalUser = true;
        shell = pkgs.zsh;
        extraGroups = [
          "networkmanager"
          "wheel"
          "docker"
          "wireshark"
        ];
        packages = with pkgs; [
          gh
          stow
        ];
      });
    })
  ];
}
