#!/usr/bin/env bash
# report.sh — aggregate agent spend from Claude Code JSON results.
#
#   report.sh [--threshold USD] [--out file.json] [--md] <result.json>...
#
# Accepts `claude -p --output-format json` results ({total_cost_usd, num_turns, duration_ms, ...}),
# claude-code-action execution files (arrays with a {type:"result"} entry), and the
# sdlc-cost.json records the CI templates write. Prints a summary JSON (or a Markdown table
# with --md) and exits 1 when the total exceeds --threshold, so a pipeline step can fail on it.
set -u
. "${0%/*}/../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"

threshold=""; out=""; md=0; files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --threshold) threshold="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --md) md=1; shift ;;
    -*) sdlc_die 2 "report.sh [--threshold USD] [--out file.json] [--md] <result.json>..." ;;
    *) files+=("$1"); shift ;;
  esac
done
[ ${#files[@]} -gt 0 ] || sdlc_die 2 "report.sh: at least one result file is required"

# Each detail row is a canonical run record: run_id and session_id are kept explicitly so
# metrics/report.py can deduplicate a summary against the raw files it was built from;
# "session" (session_id, else run_id) and "file" stay for older consumers. Files that are
# missing or not valid JSON of one of the three shapes are listed under "skipped" in the
# summary as well as noted on stderr, so a report never hides that input was dropped.
rows='[]'; skipped='[]'
skip() { sdlc_log "skipping $1 file $2"; skipped=$(jq -c --arg n "$2" '. + [$n]' <<<"$skipped"); }
for f in "${files[@]}"; do
  [ -f "$f" ] || { skip missing "$f"; continue; }
  row=$(jq -c --arg f "${f##*/}" '
    def num: if type=="number" then . else (tonumber? // 0) end;
    def str: if . == null then null else tostring end;
    (if type=="array" then ([.[] | select(.type=="result")] | last // {}) else . end) as $r
    | {file: $f, cost_usd: (($r.total_cost_usd // 0)|num), turns: (($r.num_turns // 0)|num),
       duration_ms: (($r.duration_ms // 0)|num), recorded_at: ($r.recorded_at // null),
       pr: ($r.pr // null), run_id: ($r.run_id|str), session_id: ($r.session_id|str),
       session: ($r.session_id // $r.run_id // null)}' "$f" 2>/dev/null) \
    || { skip unreadable "$f"; continue; }
  rows=$(jq -c --argjson r "$row" '. + [$r]' <<<"$rows")
done

summary=$(jq -c --arg th "${threshold:-}" --arg now "$(sdlc_iso_now)" --argjson skipped "$skipped" '
  { generated_at: $now, runs: length, skipped: $skipped,
    total_cost_usd: ([.[].cost_usd] | add // 0),
    avg_cost_usd: (if length > 0 then (([.[].cost_usd] | add) / length) else 0 end),
    max_cost_usd: ([.[].cost_usd] | max // 0),
    total_turns: ([.[].turns] | add // 0),
    threshold_usd: (if $th == "" then null else ($th|tonumber) end),
    over_threshold: (if $th == "" then false else (([.[].cost_usd] | add // 0) > ($th|tonumber)) end),
    runs_detail: . }' <<<"$rows")

if [ -n "$out" ]; then mkdir -p "$(dirname "$out")"; printf '%s\n' "$summary" >"$out"; fi
if [ $md = 1 ]; then
  jq -r '"| Runs | Total (USD) | Average (USD) | Max (USD) | Turns | Threshold (USD) |\n| --- | --- | --- | --- | --- | --- |\n| \(.runs) | \(.total_cost_usd|.*100|round/100) | \(.avg_cost_usd|.*100|round/100) | \(.max_cost_usd|.*100|round/100) | \(.total_turns) | \(.threshold_usd // "none") |"' <<<"$summary"
else
  printf '%s\n' "$summary"
fi
if jq -e '.over_threshold' <<<"$summary" >/dev/null; then
  echo "ai-sdlc: agent spend $(jq -r .total_cost_usd <<<"$summary") USD exceeds the threshold $threshold USD" >&2
  exit 1
fi
exit 0
