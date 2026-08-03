#!/usr/bin/env bash
#
# check-alert-metrics.sh -- assert that every metric referenced by a Prometheus
# alerting rule actually has series in Prometheus.
#
# WHY THIS EXISTS
#
# Prometheus reports a rule whose expression matches nothing as health=ok. An
# empty result is not an error. A rule that references a metric which does not
# exist -- because an exporter was reconfigured, a collector flag was never
# passed, or an upstream renamed a metric family -- is therefore
# indistinguishable from a healthy rule that simply has nothing to complain
# about. It will never fire and nothing will ever say so.
#
# Five such rules accumulated in this repository before anyone noticed:
#
#   DockerUnitFlapping       node_systemd_unit_restart_total  (collector flag)
#   SDRServiceFailure        promtail_custom_*                (promtail removed)
#   FeederUpstreamFailure    promtail_custom_*                (promtail removed)
#   UltrafeederNoAircraft    readsb_stats_aircraft_with_pos   (renamed upstream)
#   UltrafeederNotReceiving  readsb_stats_messages            (renamed upstream)
#
# promtool check rules will not catch this: the expressions are all valid
# PromQL. promtool test rules catches it only for rules that have a test. This
# script is the backstop that catches it for all of them.
#
# Usage:
#   scripts/check-alert-metrics.sh [PROMETHEUS_BASE_URL]
#
# Exits 0 if all metrics resolve, or if Prometheus is unreachable (so CI on a
# runner without LAN access does not fail spuriously). Exits 1 if any
# referenced metric has no series.
set -euo pipefail

PROM_URL="${1:-http://192.168.31.20:9090}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RULES_DIR="${REPO_ROOT}/modules/monitoring/master/alert-rules"

if [[ ! -d ${RULES_DIR} ]]; then
    echo "error: rules directory not found: ${RULES_DIR}" >&2
    exit 1
fi

# Reachability probe first. A runner that cannot see the LAN must skip rather
# than fail, otherwise this check becomes something people learn to ignore.
if ! curl -sfG --max-time 10 "${PROM_URL}/api/v1/status/buildinfo" >/dev/null 2>&1; then
    echo "SKIPPED: Prometheus at ${PROM_URL} is unreachable."
    echo "         This check only runs where the monitoring LAN is reachable."
    exit 0
fi

echo "Prometheus: ${PROM_URL}"
echo "Rules:      ${RULES_DIR}"
echo

# Extract metric names from every expr: field. Done in python3 with only the
# standard library, because pyyaml is not available in this repo's dev shell
# and a regex over the expression text is sufficient for the shapes used here.
#
# Emits "metric<TAB>comma,separated,files" per line.
METRIC_LIST="$(
    python3 - "${RULES_DIR}" <<'PYEOF'
import os
import re
import sys

rules_dir = sys.argv[1]

# PromQL functions, aggregation operators, keywords and modifiers. These are
# bare identifiers in an expression but are not metric names.
RESERVED = {
    "abs", "absent", "absent_over_time", "avg", "avg_over_time", "bool",
    "bottomk", "by", "ceil", "changes", "clamp", "clamp_max", "clamp_min",
    "count", "count_over_time", "count_values", "day_of_month", "day_of_week",
    "day_of_year", "days_in_month", "delta", "deriv", "exp", "floor", "group",
    "group_left", "group_right", "histogram_quantile", "hour", "idelta",
    "ignoring", "increase", "irate", "label_join", "label_replace",
    "last_over_time", "ln", "log10", "log2", "max", "max_over_time", "min",
    "min_over_time", "minute", "month", "offset", "on", "or", "predict_linear",
    "present_over_time", "quantile", "quantile_over_time", "rate", "resets",
    "round", "scalar", "sgn", "sort", "sort_desc", "sqrt", "stddev",
    "stddev_over_time", "stdvar", "stdvar_over_time", "sum", "sum_over_time",
    "time", "timestamp", "topk", "unless", "vector", "without", "year",
    "and", "if", "atan2",
}

metrics = {}

for name in sorted(os.listdir(rules_dir)):
    if not name.endswith((".yaml", ".yml")):
        continue
    path = os.path.join(rules_dir, name)
    if not os.path.isfile(path):
        continue

    text = open(path, encoding="utf-8").read()

    # Collect expr: values, including YAML block scalars (expr: | ...).
    exprs = []
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        m = re.match(r"^(\s*)expr:\s*(.*)$", lines[i])
        if not m:
            i += 1
            continue
        indent, rest = m.group(1), m.group(2).strip()
        if rest in ("|", ">", "|-", ">-", "|+", ">+"):
            block = []
            i += 1
            while i < len(lines):
                if lines[i].strip() == "":
                    block.append("")
                    i += 1
                    continue
                cur = len(lines[i]) - len(lines[i].lstrip())
                if cur <= len(indent):
                    break
                block.append(lines[i].strip())
                i += 1
            exprs.append(" ".join(block))
        else:
            # Possibly a multi-line plain scalar continued by deeper indent.
            buf = [rest]
            i += 1
            while i < len(lines):
                if lines[i].strip() == "":
                    break
                cur = len(lines[i]) - len(lines[i].lstrip())
                if cur <= len(indent) or re.match(r"^\s*\w+:", lines[i]):
                    break
                buf.append(lines[i].strip())
                i += 1
            exprs.append(" ".join(buf))

    for expr in exprs:
        # Drop label selectors wholesale: the identifiers inside them are label
        # names, not metrics. Also drop quoted strings and durations.
        cleaned = re.sub(r"\{[^{}]*\}", " ", expr)
        cleaned = re.sub(r'"[^"]*"', " ", cleaned)
        cleaned = re.sub(r"'[^']*'", " ", cleaned)
        cleaned = re.sub(r"\[[^\]]*\]", " ", cleaned)

        for ident in re.findall(r"\b[a-zA-Z_][a-zA-Z0-9_:]*\b", cleaned):
            if ident in RESERVED:
                continue
            # Recording rules use a colon and are produced by this stack, so
            # they may legitimately not exist yet.
            if ":" in ident:
                continue
            # A metric name always contains an underscore in this codebase;
            # bare words are label values or leftover keywords.
            if "_" not in ident:
                continue
            metrics.setdefault(ident, set()).add(name)

for metric in sorted(metrics):
    print(f"{metric}\t{','.join(sorted(metrics[metric]))}")
PYEOF
)"

if [[ -z ${METRIC_LIST} ]]; then
    echo "error: no metrics extracted -- the parser is probably broken" >&2
    exit 1
fi

# Metrics that legitimately have no series most of the time, because they are
# emitted only while the condition they describe is true. Their absence is the
# healthy state, so it must not be reported as a defect.
#
# Every entry needs a justification. Do not add a metric here to silence a
# genuine defect -- that defeats the entire purpose of this script.
#
#   fwupd_device_update_info
#     modules/monitoring/agent/node_exporter.nix emits one series per device
#     that has a pending firmware release. With no updates outstanding the
#     jq filter produces nothing. The companion fwupd_updates_available is
#     always emitted and is checked normally, so a broken exporter is still
#     caught.
CONDITIONAL_METRICS=(
    fwupd_device_update_info
)

is_conditional() {
    local needle="$1" entry
    for entry in "${CONDITIONAL_METRICS[@]}"; do
        [[ ${entry} == "${needle}" ]] && return 0
    done
    return 1
}

missing=0
total=0
conditional=0

while IFS=$'\t' read -r metric files; do
    [[ -z ${metric} ]] && continue
    total=$((total + 1))

    response="$(curl -sG --max-time 15 "${PROM_URL}/api/v1/query" \
        --data-urlencode "query=count(${metric})" || echo '')"

    if [[ -z ${response} ]]; then
        printf '  %-8s %-52s %s\n' "ERROR" "${metric}" "query failed (${files})"
        missing=$((missing + 1))
        continue
    fi

    count="$(printf '%s' "${response}" | python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except (ValueError, TypeError):
    print("query-error")
    sys.exit()

if payload.get("status") != "success":
    print("query-error")
else:
    result = payload.get("data", {}).get("result", [])
    print(result[0]["value"][1] if result else "0")
')"

    if [[ ${count} == "query-error" ]]; then
        printf '  %-8s %-52s %s\n' "ERROR" "${metric}" "(${files})"
        missing=$((missing + 1))
    elif [[ ${count} == "0" ]]; then
        if is_conditional "${metric}"; then
            printf '  %-8s %-52s %s\n' "COND" "${metric}" "absent while condition is false (${files})"
            conditional=$((conditional + 1))
        else
            printf '  %-8s %-52s %s\n' "MISSING" "${metric}" "(${files})"
            missing=$((missing + 1))
        fi
    else
        printf '  %-8s %-52s series=%s\n' "OK" "${metric}" "${count}"
    fi
done <<<"${METRIC_LIST}"

echo
echo "Checked ${total} metric(s); ${missing} unresolved, ${conditional} conditionally absent."

if ((missing > 0)); then
    cat <<'EOF'

FAILED: at least one alerting rule references a metric with no series.

Such a rule is reported health=ok by Prometheus and will never fire. Either
fix the metric name, enable the exporter or collector that produces it, or
delete the rule.

If the metric is produced by a scrape job or collector added in this branch
and not yet deployed, that is expected -- re-run after deploying.
EOF
    exit 1
fi

echo "All referenced metrics resolve."
