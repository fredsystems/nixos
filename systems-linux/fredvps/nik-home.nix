# Home-manager configuration for "nik" on fredvps.
# Mirrors fred's setup; identity fields are defined locally here rather than
# relying on the global specialArgs (user / verbose_name / github_email)
# which belong to fred.
{
  pkgs,
  lib,
  inputs,
  system,
  ...
}:
let
  username = "nik";
  homeDir = "/home/${username}";
  nikVerboseName = "Nik";
  nikGithubEmail = "nik@placeholder.example"; # TODO: replace with real email (github: shake-py)

  isDarwin = lib.hasSuffix "darwin" system;
  isLinux = !isDarwin;

  # Same yubikey map as fred — shared hardware
  yubikeyMap = {
    "13380413" = "~/.ssh/id_ed25519_sk.pub";
    "35681557" = "~/.ssh/id_ed25519_sk_github.pub";
  };
  yubikeyMapText = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (serial: key: "${serial} ${key}") yubikeyMap
  );
in
{
  # users/homemanager/default.nix gives us: home.stateVersion + linux-xdg.nix
  # (xdg dirs, mimeApps, fontconfig) — no user-specific fields, safe to reuse.
  imports = [
    ../../users/homemanager/default.nix
    inputs.catppuccin.homeModules.catppuccin
    inputs.nixvim.homeModules.nixvim
  ]
  ++ lib.optional isLinux inputs.niri.homeModules.niri;

  catppuccin = {
    enable = true;
    flavor = "mocha";
    accent = "lavender";
  };

  home = {
    inherit username;
    homeDirectory = homeDir;

    # Mirrors the packages added by modules/common/linux-common.nix for fred
    packages = with pkgs; [
      zoxide
      oh-my-zsh
    ];

    # Mirrors modules/common/home.nix — gitconfig fully generated
    file.".gitconfig".text = ''
      [filter "lfs"]
          required = true
          clean = git-lfs clean -- %f
          smudge = git-lfs smudge -- %f
          process = git-lfs filter-process

      [user]
          name = ${nikVerboseName}
          email = ${nikGithubEmail}

      [commit]
          gpgsign = false

      [gpg]
          program = /run/current-system/sw/bin/gpg
          format = ssh

      [core]
          pager = delta

      [interactive]
          diffFilter = delta --color-only

      [delta]
          navigate = true
          side-by-side = true

      [merge]
          conflictstyle = diff3

      [diff]
          colorMoved = default
      [include]
          path = ~/.config/git/signing.conf
    '';

    # Mirrors modules/common/home.nix
    file.".config/git/yubikey-map" = {
      text = yubikeyMapText + "\n";
    };
  };
}
