# Home-manager configuration for "nik" on fredvps.
# Mirrors fred's setup; identity fields are defined locally here rather than
# relying on the global specialArgs (user / verbose_name / github_email)
# which belong to fred.
_:
let
  username = "nik";
  homeDir = import ../../../modules/lib/home-dir.nix { inherit username; };
  nikVerboseName = "Nik";
  nikGithubEmail = "nik@placeholder.example"; # TODO: replace with real email (github: shake-py)
in
{
  # modules/base/home-base.nix gives us: home.stateVersion + xdg.nix
  # (xdg dirs, mimeApps, fontconfig) — no user-specific fields, safe to reuse.
  imports = [
    ../../../modules/base/home-base.nix
    # catppuccin's and nixvim's home-manager modules come from the builder's
    # home-manager.sharedModules, which apply to every user.
  ];

  home = {
    inherit username;
    homeDirectory = homeDir;

    # Mirrors modules/base/home.nix — gitconfig fully generated
    file.".gitconfig".text = import ../../../modules/lib/gitconfig-template.nix {
      name = nikVerboseName;
      email = nikGithubEmail;
    };
  };
}
