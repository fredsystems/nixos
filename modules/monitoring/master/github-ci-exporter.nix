# modules/monitoring/master/github-ci-exporter.nix
#
# GitHub CI visibility: open issues, open pull requests, and Actions state
# for every repository owned by sdr-enthusiasts, fredsystems, fredclausen, or
# airframesio.
#
# WHY
#
# The fleet's own CI was the one system with no monitoring. Scheduled
# workflows in particular fail silently: nothing runs on a cadence to notice
# that a weekly `update-flakes` has been broken for two months, and GitHub
# auto-disables cron triggers in a repository with no activity for 60 days,
# which stops CI without any notification at all. Both conditions were present
# in the fleet when this was first run.
#
# EXPOSURE
#
# Bound to 127.0.0.1. The exporter holds a GitHub token, so it is not
# reachable off-host; Prometheus scrapes it over loopback. No `openFirewall`,
# and deliberately no nginx vhost of its own -- unlike Karma there is no UI
# here a human needs to click.
#
# One exception, and it is narrow: hosts/linux/sdrhub/configuration.nix
# publishes `/repos.json` through the landing page's vhost with an
# *exact-match* nginx location, for that page's repository jump box. That
# document is a list of repository names and descriptions, all of them public.
# `/metrics` is not reachable through it -- an exact-match location proxies
# one path and nothing else -- and the token never leaves this host either
# way. Widening that to a prefix match, or giving the exporter a vhost of its
# own, would publish the full CI picture to anything on the LAN and is the
# thing to not do.
#
# TOKEN
#
# `github_pat_public_ro` is a classic PAT scoped to `public_repo` only. That
# is the narrowest classic scope covering issues, pull requests, and Actions
# across all three owners with one credential. It is separate from
# `github_pat` (used for nix.conf access-tokens on every host) so that
# rotating one does not disturb the other.
#
# `public_repo` does grant write on public repositories -- classic scopes have
# no read-only variant. Only a per-owner fine-grained token would be truly
# read-only, and that would require one token per owner. The exporter itself
# issues no writes.
#
# The scope also decides what is monitored: private repositories are invisible
# to it, so the personal account contributes only its public repositories.
# Widening to `repo` would grant write on every private repository in all
# three owners, which is not worth CI visibility on scratch work.
#
# The secret is delivered via systemd `LoadCredential` rather than a sops
# owner/mode, because the unit runs `DynamicUser = true` and so has no stable
# uid to chown to. Same reasoning as the Alertmanager credentials in
# prometheus.nix.
#
# The `LoadCredential` wiring itself lives in the exporter's own NixOS module
# (imported below), not here: this file only supplies `tokenFile`, which that
# module turns into `LoadCredential=token:<path>` and a `GHCI_TOKEN_FILE`
# pointing at `/run/credentials/github-ci-exporter.service/token`. Nothing
# needs to be added here, and the root-owned sops path is read by systemd
# before the service drops privileges.
{
  config,
  inputs,
  pkgs,
  ...
}:
{
  imports = [ inputs.github-ci-exporter.nixosModules.default ];

  sops.secrets.github_pat_public_ro = {
    restartUnits = [ "github-ci-exporter.service" ];
  };

  services.github-ci-exporter = {
    enable = true;
    package = inputs.github-ci-exporter.packages.${pkgs.stdenv.hostPlatform.system}.github-ci-exporter;

    # Owners, not strictly organisations: `fredclausen` is a personal account.
    # The exporter resolves both through GraphQL's `RepositoryOwner`
    # interface, so a user and an org are interchangeable here. The option
    # keeps the name `orgs` because it is also the `org` metric label, which
    # every dashboard panel and alert rule selects on.
    #
    # Only the *public* repositories of the personal account are visible,
    # because `github_pat_public_ro` is scoped to `public_repo` (see below).
    # That is deliberate: monitoring the private ones would mean a token with
    # write access to them, which is a bad trade for CI visibility on
    # scratch repositories.
    #
    # `airframesio` was added for the sdrhub landing page's repository jump
    # box, which is served from this exporter's `/repos.json` (see the
    # `= /repos.json` location in hosts/linux/sdrhub/configuration.nix). There
    # is no index-only owner list: `orgs` drives both discovery and
    # monitoring, so adding an owner here to make its repositories findable
    # also puts its CI under the alert rules in
    # alert-rules/github-alerts.yaml. That was accepted deliberately rather
    # than worked around -- airframesio's CI is worth watching on its own
    # merits. Expect an initial burst of GitHubCIFailingDefaultBranch and
    # GitHubScheduledWorkflowStale for anything already red or dormant there;
    # curate it with `denylist`/`ignorePulls` rather than by removing the
    # owner, which would also empty it out of the jump box.
    orgs = [
      "sdr-enthusiasts"
      "fredsystems"
      "fredclausen"
      "airframesio"
    ];

    listen = "127.0.0.1:9418";

    # A full sweep costs ~5 of the 5000/hour core budget once the ETag cache
    # is warm, so the interval is set by how quickly a broken build should
    # appear rather than by rate limits. Five minutes is well inside the 15m
    # `for:` clause on GitHubCIFailingDefaultBranch.
    interval = "5m";

    # Archived repositories and repositories with no workflow files are
    # dropped automatically; the denylist is only for anything that survives
    # those filters and still is not worth watching.
    denylist = [
      "airframesio/acars-decoder-typescript"
      "airframesio/coverage"
      "airframesio/flightboard"
      "airframesio/xng"
      "airframesio/data"
      "airframesio/data-archiver"
      "airframesio/acars-decoder"
    ];

    # Individual pull requests that are stuck and are not ours to unstick.
    #
    # docker-vesselalert#32 is open against a repository we do not own. It
    # conflicts with the base branch, the maintainer has shown no interest in
    # it, and it is not ours to close or convert to a draft -- the two actions
    # that would otherwise clear the alert. Left alone it fires
    # GitHubPullRequestChecksFailing indefinitely, which is the shape of alert
    # that teaches the operator to ignore the whole class.
    #
    # This suppresses only the per-PR series, so the repository's CI and every
    # other pull request on it stay monitored. Using `denylist` instead would
    # blind the exporter to all of it.
    ignorePulls = [
      "sdr-enthusiasts/docker-vesselalert#32"
    ];

    tokenFile = config.sops.secrets.github_pat_public_ro.path;
  };
}
