{
  config,
  ...
}:
{
  # Procedure for generating RS256 secret for Attic server token:
  # sudo mkdir -p /etc/attic
  # sudo bash -c 'nix run nixpkgs#openssl -- genrsa -traditional 4096 | base64 -w0 > /etc/attic/rs256.secret'
  # sudo bash -c 'echo "ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=\"$(cat /etc/attic/rs256.secret)\"" > /etc/attic/atticd.env'
  # sudo chmod 600 /etc/attic/atticd.env
  # sudo rm /etc/attic/rs256.secret
  # atticd-atticadm make-token --validity "12y" --sub "fred" --push "fred" --pull "fred" --create-cache "fred"
  # atticd-atticadm make-token --validity "12y" --sub "fred_root" --push "*" --pull "*" --create-cache "*" --delete "*" --configure-cache "*" --configure-cache-retention "*" --destroy-cache "*"
  # copy the root token to `modules/common/system.nix`
  # copy the non root one to `.github/workflows/ci-linux.yaml`
  # attic login local http://localhost:8080 <token above>
  # attic cache create fred
  # attic cache configure --retention-period "30 days" fred

  sops.secrets = {
    "atticd_env" = { };
  };

  services.atticd = {
    enable = true;

    environmentFile = config.sops.secrets."atticd_env".path;

    settings = {
      listen = "[::]:8080";
      jwt = { };

      # We’ll tune chunking later; defaults are fine for now.
      chunking = {
        nar-size-threshold = 64 * 1024;
        min-size = 16 * 1024;
        avg-size = 64 * 1024;
        max-size = 256 * 1024;
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
