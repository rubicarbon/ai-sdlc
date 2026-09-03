#!/usr/bin/env bash
# collect.sh — export the period's metrics through the adapter and render the report.
#
#   collect.sh [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--platform github|azure] [--baseline file]
#
# Defaults: the last 30 days. Writes <artifacts>/metrics/raw-<since>_<until>.json and
# report-<since>_<until>.md, using <artifacts>/metrics/baseline-*.json (newest) as the
# baseline when present, and <artifacts>/metrics/cost/ for cost per merged PR.
set -u
. "${0%/*}/../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"
. "$SDLC_PLUGIN_ROOT/scripts/_project.sh"
py=$(sdlc_python) || sdlc_die 1 "Python 3 is needed for scripts/metrics/report.py (no working python3/python found)"

since=""; until=""; platform_args=(); baseline=""
while [ $# -gt 0 ]; do
  case "$1" in
    --since) since="$2"; shift 2 ;;
    --until) until="$2"; shift 2 ;;
    --platform) platform_args=(--platform "$2"); shift 2 ;;
    --baseline) baseline="$2"; shift 2 ;;
    *) sdlc_die 2 "collect.sh [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--platform github|azure] [--baseline file]" ;;
  esac
done
[ -n "$until" ] || until=$(sdlc_today)
if [ -z "$since" ]; then
  # 30 days back without GNU date -d: python is already required
  since=$($py -c 'import datetime,sys; print((datetime.date.fromisoformat(sys.argv[1]) - datetime.timedelta(days=30)).isoformat())' "$until")
fi
art=$(sdlc_artifacts_dir); mkdir -p "$art/metrics/cost"
raw="$art/metrics/raw-${since}_${until}.json"; report="$art/metrics/report-${since}_${until}.md"

"$SDLC_PLUGIN_ROOT/bin/sdlc-platform" "${platform_args[@]+"${platform_args[@]}"}" metrics_export "$since" "$until" "$raw" >/dev/null || sdlc_die 1 "metrics_export failed"
if [ -z "$baseline" ]; then baseline=$(ls -t "$art"/metrics/baseline-*.json 2>/dev/null | head -n1 || true); fi
args=("$raw" --cost-dir "$art/metrics/cost" --out "$report")
[ -n "$baseline" ] && [ -f "$baseline" ] && args+=(--baseline "$baseline")
$py "$SDLC_PLUGIN_ROOT/scripts/metrics/report.py" "${args[@]}" >/dev/null || sdlc_die 1 "report.py failed"
jq -cn --arg raw "$raw" --arg report "$report" --arg baseline "${baseline:-}" '{raw:$raw,report:$report,baseline:(if $baseline=="" then null else $baseline end)}'
