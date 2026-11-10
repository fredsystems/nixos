# Plan 03: Flake input tracking

- **Status:** planned
- **Branches:** none yet. 3.1 is fredsystems/nixos#2809. Exporter work
  (3.4-3.7) lands in `fredsystems/github-ci-exporter`. The rest is in
  this repo.

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
runner, which has Nix and can reach the LAN Pushgateway.

### Which nodes are tracked

Every root input in `flake.lock` on `main`, plus every nested nixpkgs
node that is **not** followed to one of ours (an "owned nixpkgs", e.g.
`niri/nixpkgs`). Owned nixpkgs nodes are where EOL pins and rebuild-only
churn come from, so they are first-class, labelled by input path.

Tag-pinned inputs (`opencode`, `nix-flatpak`) are reported, not acted
on: `nix flake update` cannot move a tag, and Renovate owns them.

### Exporter: one hourly pass, conditional and batched

- `flake.lock` is read through the Contents API with the existing ETag
  cache, the same path `fetch_workflow_definition` already uses. A 304
  costs no rate limit.
- Upstream heads for every tracked node come from **one** aliased
  GraphQL query (branch or default-branch head, commit date), plus the
  open `update-<input>` PR for each input in the same query.
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

| Metric                                         | Source      | Labels                                 |
| ---------------------------------------------- | ----------- | -------------------------------------- |
| `github_flake_input_locked_timestamp_seconds`  | exporter    | `repo`, `input`, `path`, `ref`         |
| `github_flake_input_upstream_timestamp_seconds` | exporter   | `repo`, `input`, `path`, `ref`         |
| `github_flake_input_up_to_date`                | exporter    | `repo`, `input`, `path`, `ref`         |
| `github_flake_input_update_pr_open`            | exporter    | `repo`, `input`                        |
| `nixos_channel_update_timestamp_seconds`       | exporter    | `channel`                              |
| `nixos_channel_current`                        | exporter    | `channel`                              |
| `nixos_channel_tested_failed`                  | exporter    | `channel`                              |
| `flake_input_impact`                           | Pushgateway | `input`, `kind`                        |
| `flake_watch_last_run_timestamp_seconds`       | Pushgateway | none                                   |

The exporter's registry prefixes everything `github_`. The
`nixos_channel_*` families need a second, unprefixed registry rendered
alongside it; confirm `prometheus-client` encodes two registries into
one response cleanly before committing to the names.

## Alerts

New groups in `modules/monitoring/master/alert-rules/github-alerts.yaml`,
each alert with a firing and a non-firing promtool case in
`tests/github-alerts-test.yaml`:

- **`FlakeInputOutdated`**: upstream moved more than the input's
  maximum age ago, impact is `source`, and no update PR is open.
- **`FlakeInputUpdateStuck`**: an `update-<input>` PR has been open with
  failing checks for more than 3 days. #2790 and #2786 would have fired
  this.
- **`FlakeInputOnEolChannel`**: a tracked owned nixpkgs node follows a
  channel whose `nixos_channel_current` is 0.
- **`NixosChannelBlocked`**: a channel our lock tracks has not moved in
  3 days and its `tested` job is failing.
- **`FlakeWatchStale`**: the watch Action has not pushed in 3 hours.

## Execution model

Exporter subtasks (3.4-3.7) are sequential within that repo and can run
alongside this repo's 3.1-3.3. 3.8 needs a released exporter. 3.9-3.10
need only this repo. 3.11 and 3.12 need the metrics to exist.

Plan 02 is in progress. Under `plan-sequencing-discipline` this plan's
subtasks can merge as they finish, but the plan cannot be marked
complete until Plan 02 is.

## Subtasks

### Groundwork

- [ ] **3.1 Retire needsreboot's own nixpkgs.** fredclausen/nixos-needsreboot#19
      (merged) moved it to `nixos-26.05`, added a Renovate regex manager
      for the channel ref, and exported `overlays.default`. #2809 applies
      the overlay so each host builds it from its own nixpkgs, and follows
      ours. Done when #2809 merges.
- [ ] **3.2 Let Renovate keep its PRs.** Add `github[bot]` to Renovate's
      `gitIgnoredAuthors`, so the relock and opencode-hash commits no
      longer make Renovate treat its branch as edited and stop rebasing
      and automerging it (#2802 needed a manual rebase and merge).
- [ ] **3.3 Owned-nixpkgs check.** A script that lists root inputs whose
      nixpkgs is not followed (from `flake.lock`) and fails if any lacks a
      `# NOTE:` reason in `flake.nix`, wired as a pre-commit hook and a
      flake check. Add the missing reason for `nixvim` (it builds neovim
      from its own pin; decide whether that is wanted, then say so).
      Tests: a fixture lock with a justified and an unjustified input.

### Exporter (`fredsystems/github-ci-exporter`)

- [ ] **3.4 Lock model and hourly pass.** `src/flake/`: fetch
      `flake.lock` for each configured repo through the ETag cache, parse
      it, and derive the tracked node set (root inputs plus owned nixpkgs,
      with paths). A `flake_repos` option and a separate `flake_interval`
      (default `1h`, minimum enforced). Tests: wiremock Contents API,
      follows resolution, a 304 that leaves the cached set unchanged.
- [ ] **3.5 Upstream heads and update PRs.** One aliased GraphQL query
      for every tracked node's upstream head and each input's open
      `update-<input>` PR, through the existing budget pre-flight.
      Publish the `github_flake_input_*` families. Tests: query
      construction, a batch with a deleted repo, budget exhaustion keeps
      the last published values.
- [ ] **3.6 NixOS channel status.** A client for `prometheus.nixos.org`
      with its own base URL option and backoff, three instant queries per
      pass, cached and published as `nixos_channel_*`. Tests: wiremock
      responses, an upstream outage keeps the cached values and flags
      collection failure.
- [ ] **3.7 Release.** README metrics table and config docs, then tag a
      release.

### This repo

- [ ] **3.8 Wire the exporter.** Bump the `github-ci-exporter` input and
      set `flakeRepos = [ "fredsystems/nixos" ]` in
      `modules/monitoring/master/github-ci-exporter.nix`. Verify with
      `nixos-eval-impacted-hosts`, then deploy sdrhub.
- [ ] **3.9 Impact classification.** `scripts/flake-input-impact.sh
      <input>`: update one input in a scratch copy and print `none`,
      `rebuild` or `source` per the table above, reusing
      `impacted-hosts.sh`'s evaluation and adding the dev shell and
      `packages.*`. Confirm Darwin configurations evaluate on a Linux
      runner; if not, the Darwin half runs on the macOS pool. Tests: a
      fixture flake with a following input, an owned-nixpkgs input bumped
      only in its lock, and one with a source change.
- [ ] **3.10 Watch Action and policy file.** `flake-input-watch.yaml`,
      hourly on `[self-hosted, Linux]`: find moved branch-tracking inputs
      with no open update PR, classify each with 3.9, push
      `flake_input_impact` and the run timestamp to the Pushgateway, and
      dispatch `update-flakes.yaml` with `single_input` for `source`
      inputs under an `auto` policy. Move `MANUAL_INPUTS` into
      `.github/flake-input-policy.json` and read it from both workflows.
- [ ] **3.11 Alerts.** The five alerts above, with promtool cases.
- [ ] **3.12 Dashboard.** `dashboards/flake-inputs.json` in the GitHub
      folder: per-input age and impact, open update PRs, owned nixpkgs
      nodes and their channels, NixOS channel status.

## Out of scope

- Replacing `update-flakes.yaml`'s weekly run. Revisit after the watch
  Action has run for a month: if `rebuild` bumps are the only thing the
  weekly run still catches, it can stay as is or move to monthly.
- Acting on tag-pinned inputs. Renovate owns those.
- Changing which inputs follow our nixpkgs, beyond 3.1 and the `nixvim`
  decision in 3.3. `niri.cachix.org` stays configured.
- Non-GitHub inputs. Every input is `github` type today; the exporter
  reports any other type as untracked rather than guessing.
