{
  lib,
  config,
  pkgs,
  inputs,
  system,
  user,
  extraUsers ? [ ],
  ...
}:
let
  cfg = config.desktop.freminal;
  t = config.terminal;
  allUsers = [ user ] ++ extraUsers;

  # FIXME(nixpkgs-536365-ld64-mac-notification-sys): WORKAROUND, not a fix.
  #
  # The nixpkgs pin (post-bump 2026-07) ships a classic ld64 whose stubs
  # pass crashes with `Trace/BPT trap: 5` when linking any Rust binary
  # that pulls in `mac-notification-sys` (via `notify-rust`). freminal
  # 0.11.1 is such a binary (Freminal's notifications feature), so
  # every aarch64-darwin freminal build fails with exit code 133 from
  # `cctools-binutils-darwin-1010.6/bin/ld`.
  #
  # nixpkgs upstream hot-fixed the same failure for `starship` in
  # NixOS/nixpkgs#540463 by forcing that package's Rust link step to
  # use LLVM's `lld` instead of classic ld64.  Apply the same recipe
  # here to the freminal package pulled from the freminal flake input:
  #
  #   - add `llvmPackages.lld` to nativeBuildInputs
  #   - set `NIX_CFLAGS_LINK = "-fuse-ld=lld"` so rustc's link invocation
  #     picks lld
  #
  # Scoped darwin-only via `pkgs.stdenv.hostPlatform.isDarwin` so Linux
  # builds are unaffected.  The starship fix carries `TODO: Remove once
  # #536365 reaches this branch.` — the root fix is nixpkgs#536365
  # ("ld64: disable hardening again"), still OPEN against `staging`.
  #
  # Revert: once nixpkgs#536365 (or an equivalent root ld64 fix) lands
  # in our pinned nixpkgs, delete this override block and its FIXME.
  # See .github/workflows/track-upstream-fixes.yaml.
  upstreamPackage = inputs.freminal.packages.${system}.freminal;
  freminalPackage =
    if pkgs.stdenv.hostPlatform.isDarwin then
      upstreamPackage.overrideAttrs (old: {
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.llvmPackages.lld ];
        env = (old.env or { }) // {
          NIX_CFLAGS_LINK = "-fuse-ld=lld";
        };
      })
    else
      upstreamPackage;
in
{
  imports = [ ../../../modules/terminal/common.nix ];

  options.desktop.freminal = {
    enable = lib.mkEnableOption "freminal terminal emulator";
  };

  config = lib.mkIf cfg.enable {
    home-manager.users = lib.genAttrs allUsers (_: {
      programs.freminal = {
        enable = true;
        package = freminalPackage;
        settings = {
          font = {
            inherit (t.font) family;
            size = t.font.size * 1.0;
          };
          theme = {
            mode = "dark";
            dark_name = "catppuccin-mocha";
            light_name = "catppuccin-latte";
          };
          scrollback.limit = 4000;
          ui.background_opacity = t.opacity;
          security.allow_clipboard_read = true;
          cursor = {
            trail = true;
          };
          keybindings = {
            fold_previous_command = "Ctrl+Shift+S";
          };
          notifications = {
            enabled = true;
          };
        };
      };
    });
  };
}
