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

  # home-manager renamed `programs.gemini-cli` to `programs.antigravity-cli`.
  # The release-25.11 catppuccin input (server hosts) still ships a functional
  # `gemini-cli` module that sets the now-renamed `programs.gemini-cli` option,
  # tripping a fatal "option has been renamed" evaluation warning. Setting
  # `catppuccin.gemini-cli.enable = false` suppresses it there. The unstable
  # catppuccin input (desktop/darwin) replaced that module with a
  # `mkRemovedOptionModule` stub, so *defining* the option there is a fatal
  # assertion. Detect which variant is present by reading the module source:
  # the functional module references `programs.gemini-cli`, the stub does not.
  geminiCliModule = "${catppuccinInput}/modules/home-manager/gemini-cli.nix";
  catppuccinHasFunctionalGeminiCli =
    builtins.pathExists geminiCliModule
    && lib.hasInfix "programs.gemini-cli" (builtins.readFile geminiCliModule);

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
  // lib.optionalAttrs catppuccinHasFunctionalGeminiCli {
    # See `geminiCliModule` note above: only disable where the functional
    # module exists (stable). On unstable it is a removed-option stub and
    # defining it would be a fatal assertion.
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
