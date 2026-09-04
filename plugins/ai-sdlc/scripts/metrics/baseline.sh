#!/usr/bin/env bash
# baseline.sh — capture the metrics baseline BEFORE the loop changes how the team works.
#
#   baseline.sh [--since YYYY-MM-DD] [--platform github|azure] [--force]
#
# Exports the last 90 days (default) to <artifacts>/metrics/baseline-<date>.json and renders
# baseline-<date>.md. Refuses to run once Tier 1 artifacts exist (features published, REVIEW.md,
# docs/agents/issue-tracker.md, a tier above 0 in the config) because a baseline taken after the
# change is not a baseline; --force overrides and records that fact in the file.
set -u
. "${0%/*}/../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"
. "$SDLC_PLUGIN_ROOT/scripts/_project.sh"
py=$(sdlc_python) || sdlc_die 1 "Python 3 is needed for scripts/metrics/report.py (no working python3/python found)"

since=""; platform_args=(); force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --since) since="$2"; shift 2 ;;
    --platform) platform_args=(--platform "$2"); shift 2 ;;
    --force) force=1; shift ;;
    *) sdlc_die 2 "baseline.sh [--since YYYY-MM-DD] [--platform github|azure] [--force]" ;;
  esac
done
today=$(sdlc_today)
[ -n "$since" ] || since=$($py -B -c 'import datetime,sys; print((datetime.date.fromisoformat(sys.argv[1]) - datetime.timedelta(days=90)).isoformat())' "$today")
art=$(sdlc_artifacts_dir)

reasons=()
tier=$(sdlc_config '.tier' 0); [ "${tier:-0}" -ge 1 ] 2>/dev/null && reasons+=("sdlc.config.json tier is $tier (Tier 1 or above)")
[ -f "$SDLC_PROJECT_DIR/REVIEW.md" ] && reasons+=("REVIEW.md exists")
[ -f "$SDLC_PROJECT_DIR/docs/agents/issue-tracker.md" ] && reasons+=("docs/agents/issue-tracker.md exists")
ls "$art"/features/*/publish-manifest.json >/dev/null 2>&1 && reasons+=("features have been published")
ls "$art"/metrics/baseline-*.json >/dev/null 2>&1 && reasons+=("a baseline already exists under $art/metrics/")
if [ ${#reasons[@]} -gt 0 ] && [ $force = 0 ]; then
  {
    echo "ai-sdlc: REFUSING to capture a baseline: the loop is already installed, so this would not be a baseline."
    printf '  - %s\n' "${reasons[@]}"
    echo "A baseline must be taken before Tier 1. Re-run with --force to record a late snapshot; it will be labelled as such."
  } >&2
  exit 1
fi
mkdir -p "$art/metrics/cost"
raw="$art/metrics/baseline-$today.json"; report="$art/metrics/baseline-$today.md"
"$SDLC_PLUGIN_ROOT/bin/sdlc-platform" "${platform_args[@]+"${platform_args[@]}"}" metrics_export "$since" "$today" "$raw" >/dev/null || sdlc_die 1 "metrics_export failed"
if [ $force = 1 ] && [ ${#reasons[@]} -gt 0 ]; then
  jq -c --arg note "LATE BASELINE: captured after the loop was installed ($(IFS=';'; echo "${reasons[*]}"))" '.note=$note' "$raw" >"$raw.tmp" && mv "$raw.tmp" "$raw"
  echo "ai-sdlc: WARNING: this is a late baseline; the report and the file say so." >&2
fi
# -B: never write __pycache__ into the plugin directory
$py -B "$SDLC_PLUGIN_ROOT/scripts/metrics/report.py" "$raw" --out "$report" >/dev/null || sdlc_die 1 "report.py failed"
if [ $force = 1 ] && [ ${#reasons[@]} -gt 0 ]; then
  printf '\n> **Late baseline.** Captured after the loop was installed; treat it as a first period, not as the pre-adoption state.\n' >>"$report"
fi
jq -cn --arg raw "$raw" --arg report "$report" --arg since "$since" --arg until "$today" '{raw:$raw,report:$report,since:$since,until:$until}'
