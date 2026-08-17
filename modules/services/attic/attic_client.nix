# Attic client configuration for the primary user.
#
# Imported by both flake/lib/mk-system.nix and flake/lib/mk-darwin-system.nix,
# so this runs on EVERY machine in the fleet -- ten NixOS hosts and two Macs.
# That is why the default is token-less.
#
# WHY MOST MACHINES NEED NO TOKEN
#
# The `fred` cache is public and Nix pulls from it anonymously: `substituters`
# in modules/base/system.nix carries only the public NAR signing key, and there
# is no netrc anywhere in the fleet. Nix and the attic CLI are separate
# consumers that share nothing -- Nix never reads this file. So a machine that
# only ever builds needs no credential, and every server and both Macs are in
# that category.
#
# This file used to embed a `fred_root` JWT with delete and destroy-cache on
# every cache, valid until 2038, rendered world-readable into the Nix store on
# all twelve machines and committed to a public repository. See
# agent-docs/ATTIC_OPERATIONS.md for what replaced it.
#
# WHY THE TOKEN CANNOT BE A `home.file` ENTRY
#
# `home.file` writes into the Nix store and symlinks to it, which is both
# world-readable and read-only. World-readable rules out a secret; read-only
# also means `attic login` cannot work on a machine where this file is managed,
# because it writes to this exact path. Hosts that push therefore render the
# file at activation from a sops secret instead, as a real 0600 file.
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.programs.atticClient;

  endpoint = "https://attic.int.fredsystems.org";

  # HTTPS, terminating on fredhub itself -- see hosts/linux/fredhub/nginx.nix.
  #
  # This endpoint is used by the attic CLI, which sends a bearer token on every
  # request. That is the whole reason it is encrypted: atticd signs whatever it
  # is given with the cache's NAR signing key, so a push token read off the wire
  # would let an attacker place content the entire fleet then trusts.
  #
  # It is NOT the substituter. Nix pulls from
  # http://192.168.31.14:8080/fred, configured in modules/base/system.nix, and
  # never reads this file -- Nix and the attic CLI are separate consumers that
  # share nothing. That split is deliberate rather than an oversight:
  #
  #   * Reads are anonymous and every NAR is signature-checked against
  #     trusted-public-keys, so a MITM cannot inject anything Nix will accept.
  #     Plaintext there costs only the privacy of which paths are fetched.
  #   * An address and a port depend on nothing but the host being up and IP
  #     routing -- no DNS, no certificate, no nginx. That is what you want when
  #     the thing being rebuilt from the cache is the cache's own host.
  #
  # So: the credential goes over TLS, and the anonymous bulk transfer takes the
  # route with the fewest moving parts. agent-docs/ATTIC_OPERATIONS.md carries
  # the same reasoning for anyone changing either one.
  baseConfig = ''
    default-server = "local"

    [servers.local]
    endpoint = "${endpoint}"
  '';
in
{
  options.programs.atticClient = {
    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/attic/desktop_token";

      description = ''
        Path to a file containing an Attic token, read at activation time.

        When null (the default, and correct for every machine that does not
        push) `config.toml` is a plain store-managed file with no credential in
        it. Pulling does not need one.

        When set, `config.toml` is instead written at activation as a real
        0600 file with the token interpolated, so the secret never enters the
        Nix store. The path is read on the target machine, not at build time.

        Setting this makes `attic login` pointless on that host: the file is
        regenerated on every activation and any manual edit is discarded.
      '';
    };
  };

  config.home = {
    packages = [ pkgs.attic-client ];

    # Machines that do not push get the endpoint and nothing else.
    file.".config/attic/config.toml" = lib.mkIf (cfg.tokenFile == null) {
      text = baseConfig;
    };

    # Machines that do push render the same thing plus a token, at activation.
    #
    # entryAfter "writeBoundary" so this runs once Home Manager has finished
    # linking its own files -- including removing the store symlink this path
    # used to be, which would otherwise still be sitting there read-only when
    # this tries to write.
    activation.atticClientConfig = lib.mkIf (cfg.tokenFile != null) (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        atticTokenFile=${lib.escapeShellArg cfg.tokenFile}
        atticTarget="$HOME/.config/attic/config.toml"

        if [ ! -r "$atticTokenFile" ]; then
          # Fail loudly. Writing a token-less config here would look like a
          # success and then fail later, at push time, with an authentication
          # error that points nowhere near the real cause.
          echo "attic: token file $atticTokenFile is missing or unreadable." >&2
          echo "attic: see agent-docs/ATTIC_OPERATIONS.md, procedure A." >&2
          exit 1
        fi

        $DRY_RUN_CMD mkdir -p "$(dirname "$atticTarget")"

        # Create the file empty at 0600 FIRST, then write into it. A plain
        # redirect followed by chmod would leave the token in a world-readable
        # file for the instant in between; the redirect below truncates without
        # altering the mode.
        $DRY_RUN_CMD install -m 0600 /dev/null "$atticTarget"
        $DRY_RUN_CMD sh -c "cat > '$atticTarget'" <<EOF
        ${baseConfig}token = "$(cat "$atticTokenFile")"
        EOF
      ''
    );
  };
}
