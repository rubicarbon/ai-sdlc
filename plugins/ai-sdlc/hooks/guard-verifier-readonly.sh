#!/usr/bin/env bash
# guard-verifier-readonly.sh (PreToolUse: Edit|Write|NotebookEdit|Bash|PowerShell)
# The grader is never the author. When the tool call comes from the sdlc-verifier or
# sdlc-security-auditor subagent, every file edit and every write-shaped shell command is
# denied. Plugin subagents cannot carry their own hooks or permission mode, so this
# plugin-level hook is what makes their tool allowlist read-only in practice.
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
  Bash|PowerShell)
    [ -n "$HOOK_CMD" ] || exit 0
    hook_cmd_writes "$HOOK_CMD" && hook_deny "$HOOK_AGENT is read-only: this command writes files or changes git state. Run the verification command and read outputs; report what you find." ;;
esac
exit 0
