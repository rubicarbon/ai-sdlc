#!/usr/bin/env bash
# The Python unit tests for scripts/metrics/report.py (cost deduplication, data quality) pass.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
py=$(eval_python) || { echo "FAIL $EVAL_NAME: no working Python 3"; exit 1; }

out=$($py -B -m unittest discover -s "$P/evals/python" -p 'test_*.py' 2>&1); rc=$?
assert_eq "0" "$rc" "python -m unittest discover exits 0 ($(printf '%s' "$out" | tail -n 3 | tr '\n' ' '))"
assert_match 'Ran [0-9]+ tests? in' "$out" "unittest ran the report tests"
assert_match '(^|[^A-Z])OK($|[^A-Z])' "$out" "unittest reports OK"
assert_no_file "$P/evals/python/__pycache__" "no __pycache__ written into the plugin's eval dir"
assert_no_file "$P/scripts/metrics/__pycache__" "no __pycache__ written next to report.py"

eval_done
