{
  pkgs,
  lib,
  config,
  ...
}:
let
  username = config.shared.user.name;
  full_name = config.shared.user.fullName;
  inherit (config.shared) extraUsers;
in
{
  imports = [
    ../hardware
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
          "input"
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
          "input"
        ];
        packages = with pkgs; [
          gh
          stow
        ];
      });
    })
  ];
}
