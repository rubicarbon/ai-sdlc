#!/usr/bin/env bash
# Both adapters behave identically under the bundled CLI mocks.
. "${EVAL_ROOT}/_assert.sh"
out=$(EVAL_TMP="$EVAL_TMP" bash "$SDLC_PLUGIN_ROOT_FOR_EVALS/scripts/platform/conformance.sh" --platform all 2>&1); rc=$?
printf '%s\n' "$out" | grep -E '^  FAIL|^        ' | head -40
assert_eq "0" "$rc" "conformance.sh exits 0 for github and azure"
assert_match 'identical stdout key sets' "$out" "cross-platform key sets compared"
eval_done
