# Home-manager configuration for "nik" on fredvps.
# Mirrors fred's setup; identity fields are defined locally here rather than
# relying on the global specialArgs (user / verbose_name / github_email)
# which belong to fred.
{
  inputs,
  ...
}:
let
  username = "nik";
  homeDir = "/home/${username}";
  nikVerboseName = "Nik";
  nikGithubEmail = "nik@placeholder.example"; # TODO: replace with real email (github: shake-py)
in
{
  # users/homemanager/default.nix gives us: home.stateVersion + linux-xdg.nix
  # (xdg dirs, mimeApps, fontconfig) — no user-specific fields, safe to reuse.
  imports = [
    ../../users/homemanager/default.nix
    inputs.catppuccin.homeModules.catppuccin
    inputs.nixvim.homeModules.nixvim
  ];

  home = {
    inherit username;
    homeDirectory = homeDir;

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
  };
}
