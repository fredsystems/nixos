{
  lib,
  isDarwin,
  inputs,
  verbose_name,
  github_email,
  catppuccinInput ? inputs.catppuccin,
  ...
}:

let
  isLinux = !isDarwin;

  yubikeyMap = {
    "13380413" = "~/.ssh/id_ed25519_sk.pub";
    "35681557" = "~/.ssh/id_ed25519_sk_github.pub";
  };

  yubikeyMapText = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (serial: key: "${serial} ${key}") yubikeyMap
  );
in
{
  ##########################################################################
  ## Shared Home-Manager module imports
  ##########################################################################
  imports = [
    ../../modules/base/home-base.nix
    catppuccinInput.homeModules.catppuccin
    inputs.nixvim.homeModules.nixvim
  ]
  ++ lib.optional isLinux inputs.niri.homeModules.niri
  ++ lib.optional isLinux ./home-linux.nix;

  ##########################################################################
  ## .gitconfig — fully generated
  ##########################################################################
  home.file.".gitconfig".text = ''
    [filter "lfs"]
        required = true
        clean = git-lfs clean -- %f
        smudge = git-lfs smudge -- %f
        process = git-lfs filter-process

    [user]
        name = ${verbose_name}
        email = ${github_email}

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

  home.file.".config/git/yubikey-map" = {
    text = yubikeyMapText + "\n";
  };
}
