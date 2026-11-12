# OpenCode 2 from the `opencode` flake input. Lives here rather than in
# overlays/default.nix because that file is a plain overlay with no access to
# the flake inputs.
#
# Upstream pins the node_modules fixed-output hash per system in
# nix/hashes.json, but the bot PR that updates it is regularly left unmerged
# when a release is tagged, so a release can ship with a stale hash and break
# every host that installs opencode. opencode-node-modules-hashes.json holds
# the real hash for those systems, written by
# scripts/opencode-node-modules-hash.sh (run automatically on Renovate's
# opencode PRs by renovate-relock.yaml). An entry only applies to the exact
# opencode AND nixpkgs revisions it was computed for. Updating Bun can change
# the dependency hash without changing the OpenCode release.
#
# Upstream's release lock can also pin a nixpkgs whose Bun does not satisfy
# package.json's packageManager (2.2.7 locked Bun 1.4.2 against bun@1.4.4),
# and its recipe downgrades the build script's Bun check to a warning, so the
# result builds and passes `--version` but its server crashes on start. The
# assert refuses that toolchain at evaluation time, the postPatch
# re-arms upstream's own check at build time, and the install check starts
# the server.
inputs: final: _:
let
  inherit (final.stdenv.hostPlatform) system;
  inherit (final) lib;
  upstream = inputs.opencode.packages.${system}.opencode;
  toolchain = inputs.opencode.inputs.nixpkgs;
  toolchainPkgs = toolchain.legacyPackages.${system};
  bun = import ./opencode-bun.nix {
    inherit (toolchain) lib;
    inherit (lib.importJSON (inputs.opencode + "/package.json")) packageManager;
    inherit (toolchainPkgs) bun;
  };
  pinned = builtins.fromJSON (builtins.readFile ./opencode-node-modules-hashes.json);
  entry = pinned.nodeModules.${system} or null;
  hash =
    if entry != null && entry.rev == inputs.opencode.rev && entry.nixpkgsRev == toolchain.rev then
      entry.hash
    else
      null;
  # The text upstream's postPatch substitutes in for the build script's throw.
  # Only undone when present: if upstream drops or rewords the relaxation, the
  # evaluation-time assert still guards the toolchain.
  relaxedCheck = "console.warn(`Warning: This script requires bun@";
in
{
  opencode =
    assert lib.assertMsg bun.compatible
      "OpenCode requires Bun ${bun.range}, but opencode/nixpkgs (${toolchain.rev}) has Bun ${bun.version} for ${system}; run scripts/opencode-node-modules-hash.sh relock and refresh its hashes";
    upstream.overrideAttrs (old: {
      __darwinAllowLocalNetworking = true;
      node_modules =
        if hash == null then upstream.node_modules else upstream.node_modules.override { inherit hash; };

      postPatch =
        (old.postPatch or "")
        + lib.optionalString (lib.hasInfix relaxedCheck (old.postPatch or "")) ''
          substituteInPlace packages/script/src/index.ts \
            --replace-fail '${relaxedCheck}' 'throw new Error(`This script requires bun@'
        '';

      # --version never loads the server module that failed on Bun 1.4.2.
      # Exercise it in every package build, including the Linux/Darwin CI
      # host builds. Keep all state isolated from the builder's home.
      postInstallCheck = (old.postInstallCheck or "") + ''
        (
          smoke=$(mktemp -d)
          export HOME="$smoke" OPENCODE_TEST_HOME="$smoke"
          export XDG_CONFIG_HOME="$smoke/config" XDG_DATA_HOME="$smoke/data"
          export XDG_CACHE_HOME="$smoke/cache" XDG_STATE_HOME="$smoke/state"
          export OPENCODE_DB="$smoke/opencode.db" OPENCODE_PASSWORD=build-smoke
          cd "$smoke"
          "$out/bin/opencode" serve --hostname 127.0.0.1 --port 0 >server.log 2>&1 &
          server_pid=$!
          trap 'kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; rm -rf "$smoke"' EXIT
          for attempt in {1..100}; do
            if ! kill -0 "$server_pid" 2>/dev/null; then
              cat server.log
              echo "OpenCode server exited before becoming ready" >&2
              exit 1
            fi
            url=$(sed -n 's/^server listening on \(http:\/\/127.0.0.1:[0-9]*\).*$/\1/p' server.log | head -n1)
            if [ -n "$url" ] && ${toolchainPkgs.curl}/bin/curl \
              --silent --fail --max-time 1 --user opencode:build-smoke "$url/api/info" >info.json; then
              echo "OpenCode server startup check passed"
              exit 0
            fi
            sleep 0.2
          done
          cat server.log
          echo "OpenCode server did not become ready" >&2
          exit 1
        )
      '';
    });
}
