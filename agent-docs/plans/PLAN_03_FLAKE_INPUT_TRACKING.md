# Plan 03: Flake input tracking

- **Status:** complete (merged 2026-11-12), ahead of Plan 02 by the
  owner's decision; see "Execution model".
- **Branches:** this repo, 3.1 (#2809) through the watch follow-ups
  (#2829, #2832, #2834); exporter work (3.4-3.7) in
  `fredsystems/github-ci-exporter` #30-#34. sdrhub deployed 2026-11-12.

## Goal

Know, without anyone watching, when a flake input is behind upstream,
whether moving it would change anything we ship, and get an update PR
opened as soon as it does, without polling anyone harder than hourly.

The weekly `update-flakes` run and Renovate stay. This plan adds the
observation layer they lack and an event-driven path for changes that
should not wait a week.

## Background

Four failures in the same fortnight, none of them visible until a PR
went red or someone went looking:

- **opencode** shipped three releases in a row whose `nix/hashes.json`
  was stale, because the upstream bot PR that fixes it was left
  unmerged. Fixed in-repo: `renovate-relock.yaml` now verifies the
  `node_modules` hash on every bump and commits the real one
  (#2807, #2808).
- **nixos-unstable** sat at one revision for three days while the
  `brave` re-add (NixOS/nixpkgs#584534) waited behind it. The cause was
  public the whole time: `hydra_job_failed{exported_job="tested"}` was 1
  on `prometheus.nixos.org`.
- **nixos-needsreboot** built every Linux host's copy against its own
  nixpkgs, pinned to EOL `nixos-25.11`, because Renovate's `nix` manager
  cannot rename a channel ref. Nothing flagged it.
- **niri** moves several times a day, mostly `Update flake.lock`
  commits. Some are real (`niri-stable` moving to a new tag), most only
  bump niri-flake's own nixpkgs. Both change our closure, because niri
  is built from niri-flake's nixpkgs (deliberately, for
  `niri-epireyn.cachix.org`), so a closure diff alone cannot tell them
  apart.

## Decisions

### Observe and act are separate

The exporter observes and stays read-only: it already holds a
`public_repo` token, runs as a `DynamicUser` with no Nix, and is
loopback-only. Anything that needs Nix (evaluating a bump) or write
access (opening a PR) runs in a GitHub Action on a self-hosted Linux
runner, which has Nix.

The two meet through GitHub, not the LAN. The Pushgateway on sdrhub
listens on `127.0.0.1:9091` only and the runners are on fredhub, so the
Action instead writes its results to `status/flake-inputs.json` on a
dedicated `flake-watch` branch (committed only when the content
changes), and the exporter reads that file through the Contents API on
its ETag path. No listener is widened and no new secret is needed. The
Action's own liveness comes from the exporter's existing workflow
metrics.

### Which nodes are tracked

Every root input in `flake.lock` on `main`, plus every nested nixpkgs
node that is **not** followed to one of ours (an "owned nixpkgs", e.g.
`niri/nixpkgs`). Owned nixpkgs nodes are where EOL pins and rebuild-only
churn come from, so they are first-class, labelled by input path.

Each node's upstream depends on how it is locked:

| Locked as                          | Upstream is                                     | Example              |
| ---------------------------------- | ----------------------------------------------- | -------------------- |
| `github`, branch or default branch | the branch head                                 | `niri`, `nixpkgs`    |
| `github`, release tag              | the newest release tag                          | `opencode`           |
| `tarball` from `channels.nixos.org` | that channel's `channel_revision` (from 3.6)    | `catppuccin/nixpkgs` |

Tag-pinned inputs are compared against the newest tag, never the default
branch, or they would read as permanently outdated. They are reported,
not acted on: `nix flake update` cannot move a tag, and Renovate owns
them. Any other lock type is reported as untracked rather than guessed
at.

### Exporter: one hourly pass, conditional and batched

- `flake.lock` is read through the Contents API with the existing ETag
  cache, the same path `fetch_workflow_definition` already uses. A 304
  costs no rate limit.
- Upstream heads for every GitHub node come from **one** aliased
  GraphQL query (branch head, or newest tag for tag-pinned nodes, with
  commit dates), plus the open `update-<input>` PR and its number for
  each input in the same query.
- How long a node has been behind is measured from the **oldest**
  upstream commit it is missing, not the newest, so frequent upstream
  commits cannot keep resetting the clock (niri commits several times a
  day). For GitHub nodes that is the first commit of the REST compare
  `locked...head`, fetched only for nodes that moved and ETag-cached.
  Channel tarballs have no compare, so the exporter persists the time it
  first saw the node behind in its state directory.
- The flake pass runs hourly on its own interval; the existing 5-minute
  CI pass is unchanged.
- New concept, new module: `src/flake/` (lock model, upstream query,
  metrics), not more code in `collector.rs` or `rest.rs`.

### NixOS channel status: fetch and cache, don't federate

Prometheus treats a series as stale after 5 minutes without a sample,
so federating `prometheus.nixos.org` hourly would leave gaps, and
federating every few minutes is not being a good neighbour. The
exporter instead runs three instant queries hourly (`channel_revision`,
`channel_update_time`, `hydra_job_failed` for `tested` jobs), for the
channels our lock references, and re-exports the cached values on every
scrape. It is the exporter's first non-GitHub origin: its own base URL
option, a `User-Agent` that names us, backoff on failure, and no use of
the GitHub rate-limit machinery.

### Impact is decided by evaluation, not by file names

"Only `flake.lock` changed upstream" is wrong in both directions: a
lock-only bump changes our closure for inputs that own their nixpkgs
(`niri`, `colmena`, `catppuccin`, `nixvim`), and is invisible for inputs
that follow ours. The watch Action classifies each moved input by
evaluating, never building:

| Kind      | Test                                                                                  | Action          |
| --------- | ------------------------------------------------------------------------------------- | --------------- |
| `none`    | No host toplevel, dev shell or `packages.*` outPath changes                           | No PR           |
| `rebuild` | Outputs change, but not with the input's owned nixpkgs held at its old revision       | Weekly run      |
| `source`  | Outputs still change with the owned nixpkgs held at its old revision                  | PR now          |

The `rebuild` test is a second evaluation with
`--override-input <input>/nixpkgs <old rev>`. Inputs that own no nixpkgs
are `none` or `source` from the first evaluation alone. The diff reuses
`scripts/impacted-hosts.sh`'s evaluation, extended to the dev shell and
packages (the `precommit-base` and `colmena` case).

### Per-input policy lives in one file

`.github/flake-input-policy.json` maps an input to its update policy
(`auto`, `manual`) and its maximum age before alerting. `update-flakes.yaml`
reads `MANUAL_INPUTS` from it instead of an inline list, and the watch
Action and alert thresholds read it too. One source, no drift.

### Owned nixpkgs must be justified

Every input that does not follow our nixpkgs carries a `# NOTE:` comment
in `flake.nix` saying what it gains (a cache, a hash tied to upstream's
toolchain). This is checked mechanically, not by review: an input that
owns its nixpkgs without a reason is the needsreboot failure waiting to
recur.

## Metrics

Names are a starting point. 3.5 and 3.6 settle them.

| Metric                                             | Labels                                    |
| -------------------------------------------------- | ----------------------------------------- |
| `github_flake_input_locked_timestamp_seconds`      | `repo`, `input`, `path`, `ref`, `channel` |
| `github_flake_input_upstream_timestamp_seconds`    | `repo`, `input`, `path`, `ref`, `channel` |
| `github_flake_input_outdated_since_timestamp_seconds` | `repo`, `input`, `path`, `ref`, `channel` |
| `github_flake_input_commits_behind`                | `repo`, `input`, `path`, `ref`            |
| `github_flake_input_up_to_date`                    | `repo`, `input`, `path`, `ref`, `channel` |
| `github_flake_input_update_pr_open`                | `repo`, `input`, `number`                 |
| `github_flake_input_impact`                        | `repo`, `input`, `os`, `kind`             |
| `nixos_channel_update_timestamp_seconds`           | `channel`                                 |
| `nixos_channel_current`                            | `channel`                                 |
| `nixos_channel_tested_failed`                      | `channel`                                 |

All of these come from the exporter. `channel` is set for every node
that tracks a NixOS channel (a `nixos-*` / `nixpkgs-*` branch, or a
channel tarball), root inputs included, so channel alerts can join on
it. `number` matches the label on the existing `github_pull_*` series,
so an update PR joins to its age and check state.
`github_flake_input_impact` is read from the watch Action's status file,
one series per OS (`linux`, `darwin`) the input was classified on, since
each OS is evaluated on its own runner.

The exporter's registry prefixes everything `github_`. The
`nixos_channel_*` families need a second, unprefixed registry rendered
alongside it; confirm `prometheus-client` encodes two registries into
one response cleanly before committing to the names.

## Alerts

New groups in `modules/monitoring/master/alert-rules/github-alerts.yaml`,
each alert with a firing and a non-firing promtool case in
`tests/github-alerts-test.yaml`:

- **`FlakeInputOutdated`**: the node has been behind (from
  `outdated_since`) for longer than the input's maximum age, impact is
  `source`, and no update PR is open.
- **`FlakeInputUpdateStuck`**: an `update-<input>` PR, joined on
  `number` to `github_pull_*`, has been open with failing checks for more
  than 3 days. #2790 and #2786 would have fired this.
- **`FlakeInputOnEolChannel`**: any tracked node, root channel inputs
  (`nixpkgs`, `nixpkgs-stable`, `nixpkgs-kernel`) and owned nixpkgs nodes
  alike, tracks a `channel` whose `nixos_channel_current` is 0.
- **`NixosChannelBlocked`**: a channel our lock tracks has not moved in
  3 days and its `tested` job is failing.
- **`FlakeWatchStale`**: the watch workflow has had no successful run in
  3 hours (`github_workflow_last_success_timestamp_seconds`).

## Execution model

Exporter subtasks (3.4-3.7) are sequential within that repo and can run
alongside this repo's 3.1-3.3. 3.8 needs a released exporter. 3.9-3.10
need only this repo. 3.11 and 3.12 need the metrics to exist.

**Completed ahead of Plan 02, as a documented exception** to
`plan-sequencing-discipline`'s contiguous-prefix rule. Plan 02 is still in
progress, and its number cannot move now that it has started; the owner
decided (2026-11-12) that this plan completes regardless, because nothing
in it depends on Plan 02 (the receiver comparison) or the other way round.
Plan 04 completed ahead of it on the same basis.

## Subtasks

### Groundwork

- [x] **3.1 Retire needsreboot's own nixpkgs.** fredclausen/nixos-needsreboot#19
      moved it to `nixos-26.05`, added a Renovate regex manager for the
      channel ref, and exported `overlays.default`. #2809 applies the
      overlay so each host builds it from its own nixpkgs, follows ours,
      and has the exported profiles apply the overlay themselves (they
      bypass `mk-system.nix`).
- [x] **3.2 Let Renovate keep its PRs.** Add `github[bot]` to Renovate's
      `gitIgnoredAuthors`, so the relock and opencode-hash commits no
      longer make Renovate treat its branch as edited and stop rebasing
      and automerging it (#2802 needed a manual rebase and merge).
- [x] **3.3 Owned-nixpkgs check.** A script that lists root inputs whose
      nixpkgs is not followed (from `flake.lock`) and fails if any lacks a
      `# NOTE:` reason in `flake.nix`, wired as a pre-commit hook and a
      flake check. Add the two missing reasons: `nixvim` (it builds neovim
      from its own pin; decide whether that is wanted, then say so) and
      `precommit-base` (dev shell and checks only).
      Tests: a fixture lock with a justified and an unjustified input.

### Exporter (`fredsystems/github-ci-exporter`)

- [x] **3.4 Lock model and hourly pass.** `src/flake/`: fetch
      `flake.lock` for each configured repo through the ETag cache, parse
      it, and derive the tracked node set (root inputs plus owned nixpkgs,
      with paths), classifying each as branch, tag or channel tarball and
      extracting its `channel`. A `flake_repos` option and a separate
      `flake_interval` (default `1h`, minimum enforced). Tests: wiremock
      Contents API, follows resolution, a 304 that leaves the cached set
      unchanged, and a fixture with this repo's `catppuccin/nixpkgs`
      tarball node.
- [x] **3.5 Upstream heads and update PRs.** One aliased GraphQL query
      for every GitHub node's upstream (branch head, or newest tag for
      tag-pinned nodes) and each input's open `update-<input>` PR with its
      number, through the existing budget pre-flight. A REST compare for
      each node that moved, for `outdated_since` and `commits_behind`.
      Read `status/flake-inputs.json` from the `flake-watch` branch into
      `github_flake_input_impact`; until 3.10 creates it, a 404 publishes
      no impact series rather than failing the pass. Publish the
      `github_flake_input_*` families. Tests: query construction, a
      missing status file, a tag-pinned node on the newest tag reads up to date,
      `outdated_since` stays put when a second upstream commit lands, a
      batch with a deleted repo, and budget exhaustion keeping the last
      published values.
- [x] **3.6 NixOS channel status.** A client for `prometheus.nixos.org`
      with its own base URL option and backoff, three instant queries per
      pass, cached and published as `nixos_channel_*`. Channel-tarball
      nodes take their upstream revision from `channel_revision` and their
      `outdated_since` from the persisted first-seen time. Tests: wiremock
      responses, a tarball node behind its channel, and an upstream outage
      keeping the cached values and flagging collection failure.
- [x] **3.7 Release.** README metrics table and config docs
      (fredsystems/github-ci-exporter#30-#33). No tag: the exporter has
      never been tagged and this repo consumes it from `main`.

### This repo

- [x] **3.8 Wire the exporter.** Bump the `github-ci-exporter` input and
      set `flakeRepos = [ "fredsystems/nixos" ]` in
      `modules/monitoring/master/github-ci-exporter.nix`. Verify with
      `nixos-eval-impacted-hosts`, then deploy sdrhub. Done: #2825,
      deployed 2026-11-11; sdrhub publishes 34 `github_flake_input_*`
      node series and `nixos_channel_*` for 4 channels.
- [x] **3.9 Impact classification.** `scripts/flake-input-impact.sh
      <input>`: update one input in a scratch copy and print `none`,
      `rebuild` or `source` per the table above, reusing
      `impacted-hosts.sh`'s evaluation and adding the dev shell and
      `packages.*`. Each OS is classified on its own runner: Darwin
      configurations are evaluated only on the macOS pool, never on
      Linux. Tests: a fixture flake with a following input, an
      owned-nixpkgs input bumped only in its lock, and one with a source
      change.
- [x] **3.10 Watch Action and policy file.** `flake-input-watch.yaml`,
      hourly on `[self-hosted, Linux]`: find moved branch-tracking inputs
      with no open update PR, classify each with 3.9, write the results
      to `status/flake-inputs.json` on the `flake-watch` branch (commit
      only on change), and dispatch `update-flakes.yaml` with
      `single_input` for `source` inputs under an `auto` policy. Move
      `MANUAL_INPUTS` into `.github/flake-input-policy.json` and read it
      from both workflows. The exporter side (reading the status file
      into `github_flake_input_impact`) is part of 3.5. Done: the
      decisions live in `scripts/flake-watch.sh` (tested by
      `scripts/tests/flake-watch-test.sh`), Darwin is classified on the
      macOS pool, and a status entry is reused while both revisions are
      unchanged, so a quiet hour commits nothing. A dispatch is recorded
      only once it succeeded and is retried after 6 hours with no update
      PR. There is no central publish job: `find` and each OS's classify
      job publish into the latest file, so an offline runner pool holds up
      only its own OS. A cached kind is reused only while main's base
      fingerprint (`flake-input-impact.sh --base-fingerprint`) is
      unchanged, so a merge that changes what we build reclassifies
      (follow-up PR).
- [x] **3.11 Alerts.** The five alerts above, with promtool cases.
      Done: per-input maximum ages are recording rules generated from
      `.github/flake-input-policy.json`, tested by promtool as deployed;
      `FlakeWatchStale` waits 6h, not 3h, because GitHub drops scheduled
      runs heavily.
- [x] **3.12 Dashboard.** `dashboards/flake-inputs.json` in the GitHub
      folder: per-input age and impact, open update PRs, owned nixpkgs
      nodes and their channels, NixOS channel status.

### Cleanup

- [x] **3.13 actionlint in pre-commit.** Surfaced during 3.9: actionlint
      reports 9 findings in this repo, in `ci-darwin.yaml`, `ci-linux.yaml`
      and `lint.yaml` (3 each, shellcheck SC2086 unquoted variables in the
      `skip-if-clean` step those workflows share), and nothing runs it:
      `precommit-base` validates workflows only against the JSON schema
      (`check-github-workflows`). Impact: workflow shell bugs reach CI
      unflagged. Fix, in order:
      1. Fix the 9 findings here. This touches `ci-linux.yaml` and
         `ci-darwin.yaml`, which are in `FORCE_ALL_FILES`, so the PR
         builds every host.
      2. In `FredSystems/pre-commit-checks`, enable git-hooks.nix's
         built-in `actionlint` hook (it runs shellcheck on `run:` blocks)
         in the base hook set, so every consuming repo gets it.
      3. Bump `precommit-base` here.
      Scheduling: the inventory (2026-11-11) found 44 consuming repos, 27
      clean and 17 with 158 findings, 102 of them in
      sdr-enthusiasts/common-github-workflows; about 20 are `runner-label`
      findings that need a `.github/actionlint.yaml`, not workflow
      changes. Decision: enable it for every consumer now and fix each
      repo as its base bump fails, rather than an opt-in flag. Step 1 is
      #2820; step 2 is fredsystems/pre-commit-checks#88; step 3 waits on
      both.
      Verification: `actionlint` clean here; the base's
      `pre-commit-check` runs the hook; this repo's Lint passes after the
      bump.

## Out of scope

- Replacing `update-flakes.yaml`'s weekly run. Revisit after the watch
  Action has run for a month: if `rebuild` bumps are the only thing the
  weekly run still catches, it can stay as is or move to monthly.
- Acting on tag-pinned inputs. Renovate owns those.
- Changing which inputs follow our nixpkgs, beyond 3.1 and the `nixvim`
  decision in 3.3. `niri.cachix.org` stays configured.
- Lock types beyond GitHub and NixOS channel tarballs. None exist today;
  the exporter reports any other type as untracked rather than guessing.
- Exposing the Pushgateway beyond loopback. The watch results travel
  through GitHub instead.
