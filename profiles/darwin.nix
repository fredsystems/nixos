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

  # FIXME(nix-darwin-1817-toc-depth): These two lines are a WORKAROUND, not a
  # fix. nixpkgs removed the `--toc-depth` / `--chunk-toc-depth` flags from
  # `nixos-render-docs manual html` in favour of `--sidebar-depth`, but the
  # nix-darwin pin we follow still passes the old flags when building the
  # nix-darwin HTML manual (`darwin-manual-html`). That derivation now fails
  # with `--toc-depth has been removed, use --sidebar-depth instead`, which
  # breaks the whole Darwin system build the moment `nixpkgs` is bumped.
  #   - issue:  https://github.com/nix-darwin/nix-darwin/issues/1817
  #   - fix PR: https://github.com/nix-darwin/nix-darwin/pull/1819 (and #1818)
  # Two independent code paths build that broken HTML manual, so BOTH knobs
  # are required (per the issue thread; disabling docs alone is not enough):
  #   1. `documentation.doc.enable = false` drops the outer system's consumers
  #      of the broken build (`manual.manualHTML` + the `darwin-help` script),
  #      while leaving man pages (`nixos-render-docs options manpage`, which
  #      does NOT use the removed flags) intact.
  #   2. `system.tools.darwin-uninstaller.enable = false` drops the
  #      `darwin-uninstaller` package. That package (pkgs/darwin-uninstaller)
  #      evaluates a *second, inner* nix-darwin system with default options,
  #      which rebuilds its own `darwin-manual-html` and fails identically --
  #      unaffected by knob (1) because it re-enables docs internally.
  #
  # WHEN TO REVERT: once the `darwin` flake input advances to a commit that
  # contains the PR #1819/#1818 fix (uses `--sidebar-depth`), delete BOTH lines
  # below so the HTML manual and the uninstaller build again.
  # The `.github/workflows/track-upstream-fixes.yaml` workflow watches for this.
  documentation.doc.enable = false;
  system.tools.darwin-uninstaller.enable = false;

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
        cargo-watch
        zeromq
        rrdtool
      ];

      programs.firefox.enable = true;
    };

  fonts = {
    packages = with pkgs; [
      cascadia-code
      nerd-fonts.caskaydia-mono
      nerd-fonts.caskaydia-cove
    ];
  };
}
