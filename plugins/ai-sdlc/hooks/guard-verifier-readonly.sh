#!/usr/bin/env bash
# guard-verifier-readonly.sh (PreToolUse: Edit|Write|NotebookEdit|Bash|PowerShell)
# The grader is never the author. When the tool call comes from the sdlc-verifier or
# sdlc-security-auditor subagent, every file edit is denied and the shell is limited to an
# explicit allowlist:
#   - read-only commands recognised by hook_cmd_scan (cat, grep, git diff/log/show, jq, ...),
#     with no redirection to a file;
#   - read-only sdlc-platform functions (platform_detect, work_item_get, pr_get, pr_checks);
#   - the plugin's own read-only scripts (scripts/loop/precondition.sh, validate-report.sh);
#   - the isolation helper scripts/verify/run-isolated.sh, which runs the configured
#     verification command in a disposable git worktree and proves afterwards that the main
#     checkout did not change.
# Everything else (test runners in the main checkout, scripts, interpreters, build tools,
# archive extraction, downloads, git mutation, redirections, PowerShell mutation) is denied.
# Plugin subagents cannot carry their own hooks or permission mode, so this plugin-level hook
# is what makes their tool allowlist read-only in practice.
set -u
. "${0%/*}/../scripts/_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_hook.sh"

case "$HOOK_AGENT" in
  sdlc-verifier|*:sdlc-verifier|sdlc-security-auditor|*:sdlc-security-auditor) ;;
  *) exit 0 ;;
esac

helper='bash "${CLAUDE_PLUGIN_ROOT}/scripts/verify/run-isolated.sh"'
case "$HOOK_TOOL" in
  Edit|Write|NotebookEdit)
    hook_deny "$HOOK_AGENT is read-only: report the discrepancy with evidence instead of editing '$(hook_rel "${HOOK_FILE:-?}")'. Fixing is the author's job, in a separate step." ;;
  Bash|PowerShell)
    [ -n "$HOOK_CMD" ] || exit 0
    hook_cmd_scan "$HOOK_CMD"
    if [ -n "$HOOK_SCAN_TARGETS" ] || [ "$HOOK_SCAN_DYNAMIC" = 1 ]; then
      hook_deny "$HOOK_AGENT is read-only: this command writes files or redirects output into a file. Read outputs from the terminal and quote them in the report."
    fi
    if [ -n "$HOOK_SCAN_GITMETA" ]; then
      hook_deny "$HOOK_AGENT is read-only: this command changes git state. Use git diff, git log, git show and git status to read; report what you find."
    fi
    if [ -n "$HOOK_SCAN_VERIFY" ]; then
      hook_deny "$HOOK_AGENT is read-only: test runners, linters and build tools do not run in the main checkout. Run the configured verification command in an isolated worktree with $helper (add --tail N for more output) and quote its output."
    fi
    case "$HOOK_SCAN_CLASS" in
      readonly) exit 0 ;;
      plugin)
        while IFS= read -r op; do
          [ -n "$op" ] || continue
          case "$op" in
            script:scripts/verify/run-isolated.sh|script:scripts/loop/precondition.sh|script:scripts/loop/validate-report.sh) ;;
            platform:platform_detect|platform:work_item_get|platform:pr_get|platform:pr_checks) ;;
            script:*) hook_deny "$HOOK_AGENT is read-only: plugin script '${op#script:}' is not on the verifier allowlist. Run the verification command with $helper and read files with cat, grep or git show." ;;
            platform:*) hook_deny "$HOOK_AGENT is read-only: sdlc-platform ${op#platform:} changes the platform. Only platform_detect, work_item_get, pr_get and pr_checks are allowed." ;;
          esac
        done <<<"$HOOK_SCAN_PLUGIN"
        exit 0 ;;
      verify)
        hook_deny "$HOOK_AGENT is read-only: test runners and build tools do not run in the main checkout. Run the configured verification command in an isolated worktree with $helper (add --tail N for more output) and quote its output." ;;
      gitmeta|writes)
        hook_deny "$HOOK_AGENT is read-only: this command changes git state or files. Use git diff, git log, git show and git status to read; report what you find." ;;
      *)
        first=$(printf '%s' "$HOOK_SCAN_OPAQUE" | head -n1)
        hook_deny "$HOOK_AGENT is read-only: '${first:-$HOOK_CMD}' is not on the read-only allowlist (scripts, interpreters, package managers, downloads and archives are denied). Run the verification command with $helper; read files with cat, grep, git show." ;;
    esac ;;
esac
exit 0
