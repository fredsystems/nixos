# modules/monitoring/master/flake-input-policy-rules.nix
#
# Prometheus recording rules generated from .github/flake-input-policy.json,
# so the FlakeInputOutdated alert (alert-rules/github-alerts.yaml) reads each
# input's maximum age from the same file update-flakes.yaml and
# flake-input-watch.yaml read their policy from: one source, no drift
# (agent-docs/plans/PLAN_03_FLAKE_INPUT_TRACKING.md, "Per-input policy lives
# in one file").
#
#   flake_input_policy:default_max_age_seconds            the default
#   flake_input_policy:max_age_seconds{input="<name>"}    each override
#
# Takes pkgs; returns the rule file. Used by prometheus.nix and by the
# promtool check in flake/dev/checks.nix, which tests the alerts against this
# exact output.
pkgs:
let
  policy = pkgs.lib.importJSON ../../../.github/flake-input-policy.json;
  seconds = days: toString (days * 86400);
  overrides = pkgs.lib.filterAttrs (_: entry: entry ? max_age_days) (policy.inputs or { });
in
pkgs.writeText "flake-input-policy-rules.yaml" (
  builtins.toJSON {
    groups = [
      {
        name = "flake-input-policy";
        rules = [
          {
            record = "flake_input_policy:default_max_age_seconds";
            expr = "vector(${seconds policy.defaults.max_age_days})";
          }
        ]
        ++ pkgs.lib.mapAttrsToList (input: entry: {
          record = "flake_input_policy:max_age_seconds";
          expr = "vector(${seconds entry.max_age_days})";
          labels = { inherit input; };
        }) overrides;
      }
    ];
  }
)
