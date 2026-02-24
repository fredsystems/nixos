{
  pkgs,
  user,
  extraUsers ? [ ],
  verbose_name,
  github_email,
  system,
  lib,
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;
  full_name = verbose_name;
  email = github_email;
  isDarwin = lib.hasSuffix "darwin" system;
  isLinux = !isDarwin;
in
{
  config = {
    environment.systemPackages =
      with pkgs;
      [
        git
        gh
        gnupg
        delta
      ]
      ++ lib.optional isLinux pinentry-tty
      ++ lib.optional isDarwin pinentry_mac;

    programs.gnupg.agent = {
      enable = true;
      enableSSHSupport = true;
    };

    home-manager.users = lib.genAttrs allUsers (
      uname:
      let
        homeDir = if isDarwin then "/Users/${uname}" else "/home/${uname}";
      in
      {
        programs.diff-so-fancy = {
          enable = true;
          enableGitIntegration = true;
        };

        programs.git = {
          settings = {
            core = {
              email = "${email}";
              name = "${full_name}";
            };

            "credential \"https://github.com\"" = {
              helper = "!${pkgs.gh}/bin/gh auth git-credential";
            };
            "credential \"https://gist.github.com\"" = {
              helper = "!${pkgs.gh}/bin/gh auth git-credential";
            };

            gpg = {
              format = "ssh";

              ssh.allowedSignersFile = "${homeDir}/.config/git/allowed_signers";
            };
          };

          enable = true;

          signing = {
            signer = "${pkgs.gnupg}/bin/gpg";
            signByDefault = false;
          };

          lfs = {
            enable = true;
            skipSmudge = false;
          };
        };
      }
    );
  };
}
