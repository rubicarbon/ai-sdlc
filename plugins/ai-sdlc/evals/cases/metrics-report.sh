#!/usr/bin/env bash
# report.py turns the normalised export into readable Markdown with DORA keys and counterweights.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
py=$(eval_python) || { echo "FAIL $EVAL_NAME: no working Python 3"; exit 1; }
raw="$EVAL_ROOT/fixtures/metrics-raw.json"; base="$EVAL_ROOT/fixtures/metrics-baseline.json"
mkdir -p "$EVAL_TMP/cost"; cp "$EVAL_ROOT"/fixtures/cost/run-3.json "$EVAL_TMP/cost/"

out=$($py "$P/scripts/metrics/report.py" "$raw" --baseline "$base" --cost-dir "$EVAL_TMP/cost" --out "$EVAL_TMP/report.md" 2>&1); rc=$?
assert_eq "0" "$rc" "report.py exits 0 ($(printf '%s' "$out" | head -c 200))"
assert_file "$EVAL_TMP/report.md" "report written"
assert_match '# SDLC metrics: contoso/usage-digest' "$out" "title names the repo"
assert_match 'Sample: 6 merged PRs, 6 deployments \(5 successful\), 1 incidents, 1 reverts' "$out" "sample line is right"
assert_match 'Indicative only' "$out" "small sample is flagged as indicative"
assert_match '\| Deployment frequency \| 1\.1 / week' "$out" "deployment frequency = 5 successes over 31 days"
assert_match 'Change failure rate \| 33\.3%' "$out" "CFR counts the failed deploy and the reverted one (2 of 6)"
assert_match 'Revert rate \| 16\.7%' "$out" "revert rate 1 of 6"
assert_match 'PR size \(p50 / p90\) \| [0-9]+ lines / [0-9]+ lines' "$out" "PR size percentiles"
assert_match '5 of 6 PRs had size data' "$out" "null sizes are reported as missing, not zero"
assert_match 'Cost per merged PR \| \$0\.49' "$out" "cost per merged PR from cost dir (2.95 / 6)"
assert_match 'vs baseline' "$out" "baseline deltas rendered"
assert_match 'measured numbers win' "$out" "honesty paragraph present"
assert_match 'Lead time for changes \(p50 / p90\) \| [0-9.]+ (h|d) / [0-9.]+ (h|d)' "$out" "lead time computed"

json=$($py "$P/scripts/metrics/report.py" "$raw" --json)
assert_eq "6" "$(printf '%s' "$json" | jq -r '.samples.prs')" "json output has sample counts"
assert_eq "6" "$(printf '%s' "$json" | jq -r '.dora.lead_time_samples')" "lead time uses PR open date when first commit is unknown (all 6 PRs have a deployment after merge)"
assert_match '^[0-9.]+$' "$(printf '%s' "$json" | jq -r '.dora.mttr_h')" "MTTR is a number"

# empty export renders n/a instead of crashing
printf '{"platform":"azure","repo":"p/r","since":"2026-01-01","until":"2026-01-31","prs":[],"deployments":[],"incidents":[],"reverts":[]}' >"$EVAL_TMP/empty.json"
out=$($py "$P/scripts/metrics/report.py" "$EVAL_TMP/empty.json" 2>&1); rc=$?
assert_eq "0" "$rc" "empty export exits 0"
assert_match 'Deployment frequency \| n/a' "$out" "empty export shows n/a"

eval_done
