{
  config,
  pkgs,
  inputs,
  lib,
  system,
  user,
  ...
}:
with lib;
let
  cfg = config.sops_secrets.enable_secrets;
  username = user;
  isDarwin = lib.hasSuffix "darwin" system;
  isLinux = !isDarwin;

  homeDir = if isDarwin then "/Users/${username}" else "/home/${username}";
in
{
  options.sops_secrets.enable_secrets = {
    enable = mkOption {
      description = "Enable SOPS Secrets.";
      default = false;
    };
  };

  imports =
    lib.optional isLinux inputs.sops-nix.nixosModules.sops
    ++ lib.optional isDarwin inputs.sops-nix.darwinModules.sops;

  config = mkIf cfg.enable {
    environment.systemPackages = [
      pkgs.sops
    ];

    sops = {
      package = lib.mkIf isLinux (
        (pkgs.callPackage inputs.sops-nix { }).sops-install-secrets.overrideAttrs (old: {
          # Only change the go-modules FOD (fixed-output derivation) environment.
          # Do NOT set env.GOPROXY / env.GONOSUMDB here: overrideAttrs does a
          # shallow merge, so writing env.X = "..." replaces the entire `env`
          # attr and drops GOFLAGS = "-mod=vendor -trimpath" from the original
          # package — causing the binary to embed the Go store path and fail
          # Nix's disallowedReferences check.
          # The configurePhase already exports GOPROXY=off for the main build
          # (it uses the vendor directory), so those vars are not needed here.
          passthru = (old.passthru or { }) // {
            overrideModAttrs = _: _: {
              GOPROXY = "https://mirrors.aliyun.com/goproxy/";
              GONOSUMDB = "*";
              preBuild = ''
                export GOPROXY=https://mirrors.aliyun.com/goproxy/
                export GONOSUMDB="*"
              '';
            };
          };
        })
      );

      defaultSopsFile = ./secrets.yaml;
      defaultSopsFormat = "yaml";
      age.keyFile = "${homeDir}/.config/sops/age/keys.txt";

      # SSH
      secrets = {
        "fred-gpg" = {
          owner = user;
          mode = "0600";
        };

        "ssh/yubi_authorized_signing" = {
          path = "${homeDir}/.config/git/allowed_signers";
          owner = username;
          mode = "0644";
        };

        "ssh/yubi_github_pub" = {
          path = "${homeDir}/.ssh/id_ed25519_sk.pub";
          owner = username;
        };

        "ssh/yubi_github_pub_two" = {
          path = "${homeDir}/.ssh/id_ed25519_sk_github.pub";
          owner = username;
        };

        "ssh/yubi_github_private" = {
          path = "${homeDir}/.ssh/id_ed25519_sk";
          owner = username;
          mode = "0600";
        };

        "ssh/yubi_github_private_two" = {
          path = "${homeDir}/.ssh/id_ed25519_sk_github";
          owner = username;
          mode = "0600";
        };

        "ssh/id_ed25519" = {
          path = "${homeDir}/.ssh/id_ed25519";
          owner = username;
          mode = "0600";
        };
        "ssh/id_ed25519.pub" = {
          path = "${homeDir}/.ssh/id_ed25519.pub";
          owner = username;
        };
        "ssh/id_rsa.pub" = {
          path = "${homeDir}/.ssh/id_rsa.pub";
          owner = username;
        };
        "ssh/id_rsa" = {
          path = "${homeDir}/.ssh/id_rsa";
          owner = username;
          mode = "0600";
        };
        "ssh/authorized_keys" = {
          path = "${homeDir}/.ssh/authorized_keys";
          owner = username;
          mode = "0600";
        };
      };
    };

    users.users.${username} = {
      openssh.authorizedKeys.keys = [
        config.sops.secrets."ssh/id_rsa.pub".path
        config.sops.secrets."ssh/id_ed25519.pub".path
        config.sops.secrets."ssh/yubi_github_pub".path
      ];
    };
  };
}

## This is the flow for adding a new system:
# 1. Clone this repository to the new system.
# 2. Run `add_new_system_sop.sh` to generate new age keys and SSH keys ON THE NEW SYSTEM. This is safe for a new system.
# 3. Add the new age public key to `.sops.yaml`. This needs to be done on a system that already has access to the secrets.
# 4. Re-encrypt the secrets with the updated keys `sops updatekeys secrets.yaml`
# 5. Commit the updated `.sops.yaml` and `secrets.yaml` files.
# 6. Push the changes to the repository.
# 7. On the new system, pull the latest changes from the repository.
# 8. On the new system pamu2fcfg -u fred | tee ~/test.txt, copy the key to sops secrets.yaml....this is if you want yubikey
# 8. Rebuild the NixOS configuration to apply the changes and decrypt the secrets.
