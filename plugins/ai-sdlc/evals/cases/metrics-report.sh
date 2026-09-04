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

# an export whose deployment source is not configured says so instead of measuring zero
nodeploy="$EVAL_ROOT/fixtures/metrics-raw-nodeploy.json"
out=$($py "$P/scripts/metrics/report.py" "$nodeploy" 2>&1); rc=$?
assert_eq "0" "$rc" "not-configured export exits 0"
assert_match 'Sample: 3 merged PRs, deployments: source not configured, 1 incidents' "$out" \
  "sample line names the unconfigured source"
assert_match '\| Deployment frequency \| source not configured \|' "$out" \
  "deployment frequency is 'source not configured'"
assert_not_match 'Deployment frequency \| 0(\.0)? / week' "$out" "deployment frequency is not a measured 0"
assert_not_match '(^|[^0-9])0 deployments' "$out" "no zero deployment count anywhere"
assert_match 'deployments are not measured \(source not configured\)' "$out" "indicative line explains why"
assert_match '\| Change failure rate \| source not configured \|' "$out" "CFR is unavailable too"
assert_match '\| Defect escape rate \| source not configured \|' "$out" "defect escape is unavailable too"
assert_match '## Data quality' "$out" "data quality section rendered"
assert_match 'export: deployments: no pipeline named sdlc-deploy found' "$out" "export warning carried"
json=$($py "$P/scripts/metrics/report.py" "$nodeploy" --json)
assert_eq "null" "$(printf '%s' "$json" | jq -r '.dora.deployment_frequency_per_week')" \
  "json deployment frequency is null, not 0"
assert_eq "null" "$(printf '%s' "$json" | jq -r '.samples.deployments')" "json deployment sample is null"
assert_eq "not-configured" "$(printf '%s' "$json" | jq -r '.sources.deployments')" "json echoes sources"
assert_eq "1" "$(printf '%s' "$json" | jq -r '[.data_quality.warnings[] | select(startswith("export: deployments"))] | length')" \
  "json data_quality carries the export warning"

# malformed cost files are warned about, not silently skipped
mkdir -p "$EVAL_TMP/badcost"; cp "$EVAL_ROOT"/fixtures/cost/run-3.json "$EVAL_TMP/badcost/"
printf 'not json' >"$EVAL_TMP/badcost/broken.json"
printf '{"run_id":"x","total_cost_usd":"abc"}' >"$EVAL_TMP/badcost/text.json"
json=$($py "$P/scripts/metrics/report.py" "$raw" --cost-dir "$EVAL_TMP/badcost" --json)
assert_eq "2.95" "$(printf '%s' "$json" | jq -r '.counterweights.cost_total_usd')" "valid record still counted"
assert_eq "1" "$(printf '%s' "$json" | jq -r '.data_quality.cost_records')" "one canonical cost record"
assert_eq "3" "$(printf '%s' "$json" | jq -r '.data_quality.cost_files')" "three cost files examined"
assert_eq "2" "$(printf '%s' "$json" | jq -r '[.data_quality.warnings[] | select(startswith("cost: "))] | length')" \
  "two cost warnings (invalid JSON, non-numeric cost)"
out=$($py "$P/scripts/metrics/report.py" "$raw" --cost-dir "$EVAL_TMP/badcost")
assert_match 'cost: broken\.json: invalid JSON' "$out" "markdown lists the invalid file"
assert_match 'cost: text\.json: .*non-numeric cost' "$out" "markdown lists the non-numeric cost"

eval_done
