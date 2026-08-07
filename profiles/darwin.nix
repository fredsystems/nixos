{
  pkgs,
  lib,
  inputs,
  user,
  ...
}:
{
  imports = [
    inputs.home-manager.darwinModules.default
    ../modules/secrets/sops.nix
    ../features/shell
    ../features/common/btop
    ../features/common/git
    ../features/desktop/alacritty
    ../features/desktop/githubdesktop
    ../features/desktop/ghostty
    ../features/desktop/freminal
    ../features/desktop/frext
    ../features/desktop/wezterm
    ../features/desktop/zed
    ../features/desktop/yubikey
  ];

  environment = {
    systemPackages = [ pkgs.coreutils ];
    systemPath = [ "/opt/homebrew/bin" ];
    pathsToLink = [ "/Applications" ];
    variables.EDITOR = "nvim";
  };

  system = {
    defaults = {
      dock = {
        dashboard-in-overlay = false;
        magnification = false;
        orientation = "bottom";
        show-recents = false;
        tilesize = 32;
        wvous-br-corner = 1;
        wvous-bl-corner = 1;
        wvous-tl-corner = 1;
        wvous-tr-corner = 1;
      };
    };
    primaryUser = "${user}";
    stateVersion = 6;
  };

  security.pam.services = {
    sudo_local = {
      touchIdAuth = true;
      reattach = true;
      watchIdAuth = true;
    };
  };

  users.users.${user}.home = "/Users/${user}";

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-darwin";
  nixpkgs.config.allowUnfree = true;

  desktop = {
    freminal.enable = true;
    frext.enable = true;
    wezterm.enable = true;
    alacritty.enable = true;
    zed.enable = true;
  };

  deployment.role = "desktop";

  sops_secrets.enable_secrets.enable = true;

  home-manager.users.${user} =
    { pkgs, ... }:
    {
      home.packages = with pkgs; [
        wget
        unzip
        file
        lsd
        zip
        toybox
        dig
        jq
        socat
        nmap
        delta
        dateutils
        gnuplot
        zeromq
        rrdtool
      ];

      # No programs.firefox here on purpose.
      #
      # It was a bare `enable = true` with no settings, extensions or
      # policies -- purely "install a browser" -- and nixpkgs' firefox on
      # darwin is a full Gecko source build. That is only substitutable
      # when Hydra's aarch64-darwin builders have caught up with the
      # nixpkgs pin, which they routinely have not: as of 2026-08-06 the
      # newest firefox-unwrapped built for aarch64-darwin was 153.0.1
      # while x86_64-linux was already on 153.0.3, so a freshly bumped
      # pin meant compiling Firefox from source on the Mac.
      #
      # Paying hours of build time for a browser nobody here uses, with
      # zero declarative configuration to show for it, is a bad trade.
      # If it is ever wanted back, `homebrew.casks` in
      # modules/services/homebrew.nix is the native answer on macOS --
      # the linux desktops keep the real, configured firefox via
      # features/desktop/firefox, which is unaffected by this.
    };

  fonts = {
    packages = with pkgs; [
      cascadia-code
      nerd-fonts.caskaydia-mono
      nerd-fonts.caskaydia-cove
    ];
  };
}
