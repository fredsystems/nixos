# modules/monitoring/master/github-ci-exporter.nix
#
# GitHub CI visibility: open issues, open pull requests, and Actions state
# for every repository in the sdr-enthusiasts and fredsystems organisations.
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
# and deliberately no nginx vhost -- unlike Karma there is nothing here a
# human needs to click.
#
# TOKEN
#
# `github_pat_public_ro` is a classic PAT scoped to `public_repo` only. That
# is the narrowest classic scope covering issues, pull requests, and Actions
# across both organisations with one credential. It is separate from
# `github_pat` (used for nix.conf access-tokens on every host) so that
# rotating one does not disturb the other.
#
# `public_repo` does grant write on public repositories -- classic scopes have
# no read-only variant. Only a per-organisation fine-grained token would be
# truly read-only, and that would require one token per org. The exporter
# itself issues no writes.
#
# The secret is delivered via systemd `LoadCredential` rather than a sops
# owner/mode, because the unit runs `DynamicUser = true` and so has no stable
# uid to chown to. Same reasoning as the Alertmanager credentials in
# prometheus.nix.
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

    orgs = [
      "sdr-enthusiasts"
      "fredsystems"
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
    denylist = [ ];

    tokenFile = config.sops.secrets.github_pat_public_ro.path;
  };
}
