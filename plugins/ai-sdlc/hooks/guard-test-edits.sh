#!/usr/bin/env bash
# guard-test-edits.sh (PreToolUse: Edit|Write|NotebookEdit)
# While <artifacts>/FIX_MODE exists, edits to test files are denied: a bug fix cannot be
# made to pass by changing the test. This is the deterministic backstop under the
# mattpocock-skills:tdd and diagnosing-bugs prose. See ai-sdlc:sdlc-loop, "Bug fixes".
set -u
. "${0%/*}/../scripts/_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_hook.sh"

[ -e "$HOOK_ARTIFACTS/FIX_MODE" ] || exit 0
[ -n "$HOOK_FILE" ] || exit 0

defaults=("**/*.test.*" "**/*.spec.*" "**/*_test.*" "**/test_*.py" "**/__tests__/**" "**/tests/**" "**/test/**" "**/*.feature" "**/testdata/**" "**/fixtures/**")
mapfile -t patterns < <(hook_list '.guardrails.testGlobs' "${defaults[@]}")
rel=$(hook_rel "$HOOK_FILE")
if SDLC_PROJECT_DIR="$HOOK_PROJECT" sdlc_glob_any "$rel" "${patterns[@]}"; then
  hook_deny "FIX_MODE is armed: '$rel' is a test file and stays frozen while the fix is in progress. Fix the code under test. If the test itself is wrong, say so to the user; they can run 'rm $(hook_rel "$HOOK_ARTIFACTS")/FIX_MODE', let you edit the test, and re-arm."
fi
exit 0
