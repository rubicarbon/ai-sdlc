#!/usr/bin/env bash
# cost/report.sh aggregates the three result formats and enforces the threshold.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
F="$EVAL_ROOT/fixtures/cost"

out=$(bash "$P/scripts/cost/report.sh" "$F"/run-1.json "$F"/run-2.json "$F"/run-3.json --out "$EVAL_TMP/cost.json"); rc=$?
assert_eq "0" "$rc" "report.sh exits 0 without a threshold"
assert_eq "3" "$(printf '%s' "$out" | jq -r .runs)" "three runs aggregated"
assert_eq "5" "$(printf '%s' "$out" | jq -r '.total_cost_usd')" "total 1.42 + 0.63 + 2.95 = 5"
assert_eq "58" "$(printf '%s' "$out" | jq -r '.total_turns')" "turns summed across formats"
assert_file "$EVAL_TMP/cost.json" "summary written"

out=$(bash "$P/scripts/cost/report.sh" --threshold 4 "$F"/run-1.json "$F"/run-2.json "$F"/run-3.json 2>&1 >/dev/null); rc=$?
assert_eq "1" "$rc" "over threshold exits 1"
assert_match 'exceeds the threshold 4 USD' "$out" "threshold message"

out=$(bash "$P/scripts/cost/report.sh" --threshold 10 --md "$F"/run-1.json "$F"/run-2.json); rc=$?
assert_eq "0" "$rc" "under threshold exits 0"
assert_match '^\| Runs \| Total \(USD\)' "$out" "markdown table header"
assert_match '\| 2 \| 2\.05 \|' "$out" "markdown totals"

# report.py consumes the summary written by report.sh
py=$(eval_python) || { echo "FAIL $EVAL_NAME: no working Python 3"; exit 1; }
mkdir -p "$EVAL_TMP/costdir"; cp "$EVAL_TMP/cost.json" "$EVAL_TMP/costdir/"
total=$($py "$P/scripts/metrics/report.py" "$EVAL_ROOT/fixtures/metrics-raw.json" --cost-dir "$EVAL_TMP/costdir" --json | jq -r '.counterweights.cost_total_usd')
assert_eq "5.0" "$total" "report.py reads report.sh summaries from the cost dir"

eval_done
