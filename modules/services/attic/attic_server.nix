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
  # copy the root token to `modules/base/system.nix`
  # copy the non root one to `.github/workflows/ci-linux.yaml`
  # attic login local http://localhost:8080 <token above>
  # attic cache create fred
  # attic cache configure fred --public
  #
  # Deliberately NOT run: `attic cache configure --retention-period ... fred`.
  # Retention is set declaratively below via the server-wide default, so it
  # survives the cache being destroyed and recreated. A per-cache value
  # overrides the global default (attic coalesces cache.retention_period with
  # the server default), so setting it by hand would silently take precedence
  # over this file.

  sops.secrets = {
    # restartUnits is load-bearing, not decoration.
    #
    # This file is passed to atticd as `environmentFile`, which systemd reads
    # once at process start. The unit references it by a path that never
    # changes, so editing the secret's VALUE produces a byte-identical unit:
    # switch-to-configuration sees no change, restarts nothing, and atticd goes
    # on serving with the old key held in memory.
    #
    # That is not hypothetical. It happened during the 2026-08-17 key rotation.
    # The new signing key deployed to /run/secrets correctly, and
    # `atticd-atticadm` -- which reads that file directly -- duly minted tokens
    # against it. But the running daemon had not restarted since 2026-08-08, so
    # it still validated against the OLD key and rejected every new token.
    #
    # The symptom was maximally confusing: attic push failed with a 403
    # AccessError, identical with and without a token, because a signature it
    # cannot verify makes the request anonymous rather than producing an
    # authentication error. It looked like a permissions problem on a token
    # whose permissions were correct.
    #
    # Worse, the rotation had silently not taken effect at all -- the leaked
    # token stayed valid the entire time it appeared to have been revoked.
    #
    # sops-install-secrets resolves restartUnits at activation by comparing the
    # decrypted bytes, so this restarts atticd only when the key actually
    # changes. Same mechanism, and the same reasoning, as
    # modules/services/mk-container-secret.nix.
    "atticd_env" = {
      restartUnits = [ "atticd.service" ];
    };
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

      garbage-collection = {
        # NOT the upstream default of 12 hours, deliberately.
        #
        # Orphan chunk reaping is capped at 500 chunks per pass, hardcoded
        # per database backend in attic's gc.rs (`DatabaseBackend::Sqlite
        # => 500`, sized to SQLite's old 999-variable statement limit), and
        # the reaper does NOT loop -- it deletes one batch and returns. So
        # throughput is entirely a function of how often a pass runs:
        #
        #   capacity = 500 chunks x passes per day
        #
        # This cache produces roughly 16,000 orphan chunks/day (3.1M
        # accumulated between 2026-01-27 and 2026-08-06). At the upstream
        # 12h interval capacity is 1,000/day -- 16x short, so the backlog
        # grows forever. That is exactly what happened: by 2026-08-06 there
        # were 3,120,701 unreclaimed chunks holding ~82 GiB, on a 138 GiB
        # store, and nothing had ever been reaped.
        #
        # 15 minutes gives 96 passes/day = 48,000 chunks/day, ~3x headroom.
        # The per-pass cost is one full-table UPDATE over the chunk table
        # (~1.0s at 4.9M rows, ~0.4s at 1.8M), so this is ~40s/day of write
        # locking against the live daemon.
        #
        # To drain a large existing backlog, temporarily set this to "5s",
        # deploy, watch `sudo du -sh /var/lib/atticd/storage` until it
        # levels off, then restore. Do it while CI is quiet: the repeated
        # write lock contends with pushes.
        interval = "15 minutes";
        #interval = "5s";

        # Time-based expiry. Attic deletes an object only when BOTH its
        # created_at and last_accessed_at are older than the cutoff, and
        # last_accessed_at is bumped only when a client actually downloads
        # the NAR (not on a bare .narinfo lookup). So this is "delete
        # anything nothing has fetched in 30 days", not an LRU eviction:
        # there is no size cap and nothing is freed early under disk
        # pressure.
        #
        # Until this was set, default-retention-period was the upstream
        # default of zero, which excludes every cache from time-based GC
        # entirely.
        #
        # Interaction with the cache-warming jobs, worth knowing before
        # shortening this:
        #   - cache-flake-inputs.yaml pushes flake input sources. Cold CI
        #     runners download every one of them on every job, so they are
        #     bumped constantly and never expire.
        #   - scripts/attic-push.sh pushes build closures. Those are only
        #     downloaded when CI actually has to build something, so a
        #     rarely used build dep can expire. That is fine: the next
        #     build refetches it from cache.nixos.org and re-pushes it.
        default-retention-period = "30 days";
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
