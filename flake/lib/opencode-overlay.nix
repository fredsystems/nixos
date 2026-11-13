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
  rearmBunCheck =
    old:
    (old.postPatch or "")
    + lib.optionalString (lib.hasInfix relaxedCheck (old.postPatch or "")) ''
      substituteInPlace packages/script/src/index.ts \
        --replace-fail '${relaxedCheck}' 'throw new Error(`This script requires bun@'
    '';
in
{
  opencode =
    assert lib.assertMsg bun.compatible
      "OpenCode requires Bun ${bun.range}, but opencode/nixpkgs (${toolchain.rev}) has Bun ${bun.version} for ${system}; run scripts/opencode-node-modules-hash.sh relock and refresh its hashes";
    upstream.overrideAttrs (old: {
      __darwinAllowLocalNetworking = true;
      node_modules =
        if hash == null then upstream.node_modules else upstream.node_modules.override { inherit hash; };

      postPatch = rearmBunCheck old;

      # FIXME(opencode-60676-desktop-service-channel): WORKAROUND, not a fix.
      # Drop this env override once the pinned release carries
      # anomalyco/opencode#60683 (desktop discovers service-prod.json);
      # tracked by .github/workflows/track-upstream-fixes.yaml.
      #
      # The channel compiled into the CLI picks the background service's
      # registration file and fixed port. Upstream's recipe builds "prod"
      # (service-prod.json), but the desktop app only discovers "latest"'s
      # service.json (anomalyco/opencode#60676), so with "prod" it waits forever
      # for a server it started. "latest" is what official releases use, so the
      # TUI and the desktop share one service as upstream intends, against the
      # same opencode.db as "prod". The updater can't install over a store path
      # either way; features/ai/opencode disables its update check.
      env = old.env // {
        OPENCODE_CHANNEL = "latest";
      };

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

  # Upstream's desktop recipe takes src, node_modules and the bundled CLI from
  # its `opencode` argument, so passing ours carries the pinned hash, the Bun
  # assert and the server-startup check into it. Everything else (Bun,
  # Electron) still comes from opencode/nixpkgs, as upstream builds it. The
  # recipe relaxes the Bun check in its own postPatch, so re-arm it here too.
  #
  # FIXME(opencode-59601-desktop-cli-dist): WORKAROUND, not a fix. Drop the
  # buildPhase override below (stagedDist/readsDist) once the pinned release
  # carries the fix for anomalyco/opencode#59601; tracked by
  # .github/workflows/track-upstream-fixes.yaml.
  #
  # The recipe stages the CLI in $OPENCODE_CLI_DIST, but since upstream's
  # 6996bbcd6 packages/desktop/script/build.ts only looks in ../cli/dist and
  # a prod build throws without it. Stage it there instead, only while the two
  # disagree, so a fix on either side upstream makes this a no-op.
  #
  # The recipe copies the CLI's env, but the desktop reads OPENCODE_CHANNEL as
  # its own identity (local/dev/beta/prod, anything else is "dev": app name,
  # app id, data dir), so it keeps "prod" while the CLI it bundles is "latest".
  #
  # At launch the desktop copies its bundled CLI into
  # ~/.config/ai.opencode.desktop/cli/<version>-<arch>/ and reuses any copy
  # already there. Ours is a wrapper that execs an absolute store path, so a
  # rebuild that keeps the version (a channel or patch change) would leave the
  # desktop running the old build's copy, and once GC removes that store path
  # the copy runs nothing at all. Reuse a staged copy only while it is
  # byte-identical to the bundled one (a ~20 KB wrapper); otherwise the existing
  # copy-and-rename replaces it. Stage names and their cleanup are untouched.
  # --replace-fail, so an upstream rewrite of this code fails the build rather
  # than silently bringing the stale reuse back.
  opencode-desktop =
    let
      stagedDist = ''export OPENCODE_CLI_DIST="$TMPDIR/desktop-cli"'';
      readsDist = lib.hasInfix "OPENCODE_CLI_DIST" (
        builtins.readFile (inputs.opencode + "/packages/desktop/script/build.ts")
      );
    in
    (inputs.opencode.packages.${system}.opencode-desktop.override { inherit (final) opencode; })
    .overrideAttrs
      (old: {
        postPatch = rearmBunCheck old + ''
          substituteInPlace packages/desktop/src/main/service/desktop-cli.ts \
            --replace-fail 'if (existsSync(destination)) {' \
                           'if (existsSync(destination) && readFileSync(destination).equals(readFileSync(source))) {'
        '';
        env = old.env // {
          OPENCODE_CHANNEL = "prod";
        };
        buildPhase =
          if !readsDist && lib.hasInfix stagedDist old.buildPhase then
            lib.replaceStrings [ stagedDist ] [ ''export OPENCODE_CLI_DIST="$PWD/../cli/dist"'' ] old.buildPhase
          else
            old.buildPhase;
      });
}
