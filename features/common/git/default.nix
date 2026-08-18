{
  pkgs,
  user,
  extraUsers ? [ ],
  verbose_name,
  github_email,
  lib,
  ...
}:
let
  allUsers = [ user ] ++ extraUsers;
  full_name = verbose_name;
  email = github_email;
  inherit (pkgs.stdenv.hostPlatform) isDarwin;
  isLinux = !isDarwin;
in
{
  config = {
    environment.systemPackages = [
      pkgs.git
      pkgs.gh
      pkgs.gnupg
      pkgs.delta
    ]
    ++ lib.optional isLinux pkgs.pinentry-tty
    ++ lib.optional isDarwin pkgs.pinentry_mac;

    programs.gnupg.agent = {
      enable = true;
      enableSSHSupport = true;
    };

    home-manager.users = lib.genAttrs allUsers (
      uname:
      let
        homeDir = import ../../../modules/lib/home-dir.nix {
          username = uname;
          inherit isDarwin;
        };
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
            # Format is managed via settings.gpg.format = "ssh" above;
            # null avoids a conflicting default from the signing option.
            format = null;
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
