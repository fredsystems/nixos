{
  lib,
  options,
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
  ++ lib.optional isLinux ./home-linux.nix;

  ##########################################################################
  ## catppuccin (home-manager)
  ##########################################################################
  # `autoEnable` was introduced in catppuccin/nix #817 (post-25.11). The
  # release-25.11 input used by server hosts does not have this option yet,
  # so guard the assignment on its presence. Setting it to `false` keeps
  # current behavior (per-port enables remain explicit in feature modules)
  # and suppresses the "catppuccin/nix will soon auto enroll ports" warning
  # at the home-manager profile level on hosts pinned to unstable.
  catppuccin = {
    enable = true;
    flavor = "mocha";
    accent = "lavender";
  }
  // lib.optionalAttrs (options.catppuccin ? autoEnable) {
    autoEnable = true;
  }
  // lib.optionalAttrs (options.catppuccin ? gemini-cli) {
    # home-manager renamed `programs.gemini-cli` to `programs.antigravity-cli`.
    # The release-25.11 catppuccin input used by server hosts still ships the
    # `gemini-cli` module, which sets the renamed option and trips an
    # "option has been renamed" evaluation warning (fatal in CI). Disable it
    # where the option still exists; unstable catppuccin dropped the module
    # entirely, so the guard keeps this from breaking desktop/darwin builds.
    gemini-cli.enable = false;
  };

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
