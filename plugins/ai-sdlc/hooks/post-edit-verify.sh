#!/usr/bin/env bash
# post-edit-verify.sh (PostToolUse: Edit|Write)
# Runs the configured formatter, then the linter, on the file that was just edited.
# Formatter failures are ignored (formatting is best effort); linter failures exit 2 so
# Claude sees the first lines and fixes them now instead of at review time.
# Silent when commands.format and commands.lint are absent or the file type is not listed.
set -u
HOOK_FAIL_OPEN=1
. "${0%/*}/../scripts/_root.sh" || exit 0
. "$SDLC_PLUGIN_ROOT/scripts/_hook.sh"

[ -n "$HOOK_FILE" ] && [ -f "$HOOK_FILE" ] || exit 0
fmt=$(sdlc_config '.commands.format' ''); lint=$(sdlc_config '.commands.lint' '')
[ -n "$fmt$lint" ] || exit 0

ext="${HOOK_FILE##*.}"; ext="${ext,,}"
mapfile -t exts < <(hook_list '.guardrails.verifyExtensions' ts tsx js jsx mjs cjs py go rs cs java kt rb php sh bash)
match=0; for e in "${exts[@]}"; do [ "$e" = "$ext" ] && match=1; done
[ $match = 1 ] || exit 0

cd "$HOOK_PROJECT" 2>/dev/null || exit 0
rel=$(hook_rel "$HOOK_FILE")
if [ -n "$fmt" ]; then bash -c "$fmt \"\$1\"" _ "$rel" >/dev/null 2>&1 || true; fi
if [ -n "$lint" ]; then
  out=$(bash -c "$lint \"\$1\"" _ "$rel" 2>&1); rc=$?
  if [ $rc -ne 0 ]; then
    { echo "ai-sdlc post-edit-verify: '$lint $rel' failed (exit $rc). Fix these before moving on:"; printf '%s\n' "$out" | head -n 25; } >&2
    exit 2
  fi
fi
exit 0
