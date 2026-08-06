# FIXME(attic-gc-sqlite-chunk-limit): WORKAROUND, not a fix.
#
# attic's orphan-chunk reaper deletes at most `orphan_chunk_limit` chunks
# per garbage-collection pass and then RETURNS -- there is no drain loop
# (server/src/gc.rs, `run_reap_orphan_chunks`). For SQLite that limit is
# hardcoded to 500:
#
#   sea_orm::DatabaseBackend::Sqlite => 500,
#   // Default statement limit imposed by sqlite:
#   // https://www.sqlite.org/limits.html#max_variable_number
#
# The limit exists because the subsequent `DELETE FROM chunk WHERE id IN
# (?, ?, ...)` binds one variable per chunk. But the cited ceiling is
# SQLite's PRE-3.32 default of 999, obsolete since 2020. The SQLite
# actually compiled into this binary reports:
#
#   sqlite version       3.46.0
#   MAX_VARIABLE_NUMBER  32766
#
# so upstream is leaving ~65x on the table.
#
# Why this matters here rather than being cosmetic: throughput is
# `limit x passes/day`, and each pass first runs a full-table UPDATE over
# the chunk table (~1s at 4.9M rows) to mark new orphans. At 500/pass
# that fixed cost is paid per 500 chunks. This cache accumulated
# 3,120,701 unreclaimed chunks holding ~82 GiB of a 138 GiB store, and at
# the upstream default 12h interval it would have needed ~8.5 years to
# drain. See the interval rationale in
# modules/services/attic/attic_server.nix.
#
# 10,000 keeps 3x headroom under 32,766 while amortising the per-pass
# table scan over 20x more work.
#
# Revert: once upstream raises the SQLite limit or (better) makes the
# reaper loop until drained, delete this overlay, its entry in
# overlays/default.nix, and this FIXME. Confirm with
# `nix build .#nixosConfigurations.fredhub.config.system.build.toplevel`
# and check a GC pass still reports sane `Deleted N orphan chunks`.
# See .github/workflows/track-upstream-fixes.yaml.
#
# Usage in overlays/default.nix:
#   attic-server = final.callPackage ./attic-server.nix {
#     inherit (prev) attic-server;
#   };
{
  attic-server,
}:
attic-server.overrideAttrs (
  _finalAttrs: prevAttrs: {
    postPatch = (prevAttrs.postPatch or "") + ''
      substituteInPlace server/src/gc.rs \
        --replace-fail \
          'sea_orm::DatabaseBackend::Sqlite => 500,' \
          'sea_orm::DatabaseBackend::Sqlite => 10000,'
    '';
  }
)
