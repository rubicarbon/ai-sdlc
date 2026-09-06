#!/usr/bin/env bash
# guard-verifier-readonly.sh (PreToolUse: Edit|Write|NotebookEdit)
# The grader is never the author. When the tool call comes from the sdlc-verifier or
# sdlc-security-auditor subagent, every file edit is denied. Their shell is not restricted: the
# agent prompts ask them to run the verification command and report, never to fix, and the
# verification report has to say which tree was verified (see agents/sdlc-verifier.md). Plugin
# subagents cannot carry their own permission mode, so this plugin-level hook is what keeps
# their file tools read-only in practice.
set -u
. "${0%/*}/../scripts/_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_hook.sh"

case "$HOOK_AGENT" in
  sdlc-verifier|*:sdlc-verifier|sdlc-security-auditor|*:sdlc-security-auditor) ;;
  *) exit 0 ;;
esac

case "$HOOK_TOOL" in
  Edit|Write|NotebookEdit)
    hook_deny "$HOOK_AGENT is read-only: report the discrepancy with evidence instead of editing '$(hook_rel "${HOOK_FILE:-?}")'. Fixing is the author's job, in a separate step." ;;
esac
exit 0
