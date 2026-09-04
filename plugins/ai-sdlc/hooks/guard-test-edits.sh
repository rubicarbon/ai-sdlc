#!/usr/bin/env bash
# guard-test-edits.sh (PreToolUse: Edit|Write|NotebookEdit|Bash|PowerShell)
# While <artifacts>/FIX_MODE exists, changes to test files are denied: a bug fix cannot be
# made to pass by changing the test. This is the deterministic backstop under the
# mattpocock-skills:tdd and diagnosing-bugs prose. See ai-sdlc:sdlc-loop, "Bug fixes".
#
# Shell commands go through hook_cmd_scan (scripts/_hook.sh). Under FIX_MODE:
#   - read-only commands, test runners, the configured verify/lint commands, git metadata
#     operations, plugin scripts and sdlc-platform calls run;
#   - write commands run when every visible target is outside guardrails.testGlobs;
#   - dynamic targets and opaque commands (scripts, interpreters, package managers, downloads,
#     archives, unknown commands) are denied, because the guard cannot prove they leave the
#     tests alone.
set -u
. "${0%/*}/../scripts/_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_hook.sh"

[ -e "$HOOK_ARTIFACTS/FIX_MODE" ] || exit 0

defaults=("**/*.test.*" "**/*.spec.*" "**/*_test.*" "**/test_*.py" "**/__tests__/**" "**/tests/**" "**/test/**" "**/*.feature" "**/testdata/**" "**/fixtures/**")
mapfile -t patterns < <(hook_list '.guardrails.testGlobs' "${defaults[@]}")
is_test() { SDLC_PROJECT_DIR="$HOOK_PROJECT" sdlc_glob_any "$1" "${patterns[@]}"; }
art_rel=$(hook_rel "$HOOK_ARTIFACTS")
unarm="If the test itself is wrong, say so to the user; they can run 'rm $art_rel/FIX_MODE', let you edit the test, and re-arm."

case "$HOOK_TOOL" in
  Edit|Write|NotebookEdit)
    [ -n "$HOOK_FILE" ] || exit 0
    rel=$(hook_rel "$HOOK_FILE")
    is_test "$rel" || exit 0
    hook_deny "FIX_MODE is armed: '$rel' is a test file and stays frozen while the fix is in progress. Fix the code under test. $unarm" ;;
  Bash|PowerShell)
    [ -n "$HOOK_CMD" ] || exit 0
    hook_cmd_scan "$HOOK_CMD"
    case "$HOOK_SCAN_CLASS" in
      readonly|verify|gitmeta|plugin) exit 0 ;;
    esac
    if [ -n "$HOOK_SCAN_OPAQUE" ]; then
      first=$(printf '%s' "$HOOK_SCAN_OPAQUE" | head -n1)
      hook_deny "FIX_MODE is armed: '$first' runs a script, interpreter or tool whose file writes the guard cannot see, so it could change a test. Use the Edit tool on non-test files, the configured verify command, or a write command that names its files. $unarm"
    fi
    if [ "$HOOK_SCAN_DYNAMIC" = 1 ]; then
      hook_deny "FIX_MODE is armed: the command writes to a target the guard cannot resolve statically (a variable, glob or unknown working directory), so it could change a test. Name the files explicitly. $unarm"
    fi
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      is_test "$t" || continue
      hook_deny "FIX_MODE is armed: the command writes the test file '$t', which stays frozen while the fix is in progress. Fix the code under test. $unarm"
    done < <(hook_scan_targets_rel)
    exit 0 ;;
esac
exit 0
