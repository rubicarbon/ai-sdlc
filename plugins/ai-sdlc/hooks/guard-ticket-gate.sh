#!/usr/bin/env bash
# guard-ticket-gate.sh (PreToolUse: Edit|Write|NotebookEdit|Bash|PowerShell)
# Nothing is implemented without an accepted ticket. When guardrails.requireTicket is on
# (default from tier 2), source changes are denied until <artifacts>/ACTIVE_TICKET names the
# ticket being built. Documentation, specs, tickets, ADRs and the glossary stay editable so
# the earlier stages of the loop can run.
#
# Shell commands are classified by hook_cmd_scan (scripts/_hook.sh). Without a ticket:
#   - read-only commands, test runners, git metadata operations, plugin scripts and
#     sdlc-platform calls run;
#   - write commands run only when every target is visible in the command text and matches a
#     ticket-free path;
#   - a dynamic target ($var, glob, backtick, home shorthand) and any opaque command
#     (interpreters, scripts, package managers, downloads, archives, unknown commands) are
#     denied, because the guard cannot prove they leave source alone.
set -u
. "${0%/*}/../scripts/_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_hook.sh"

require=$(sdlc_config '.guardrails.requireTicket' '')
if [ -z "$require" ]; then tier=$(sdlc_config '.tier' 0); [ "${tier:-0}" -ge 2 ] 2>/dev/null && require=true || require=false; fi
[ "$require" = true ] || exit 0
[ -s "$HOOK_ARTIFACTS/ACTIVE_TICKET" ] && exit 0

art_rel=$(hook_rel "$HOOK_ARTIFACTS")
allowed=("$art_rel/**" ".scratch/**" "docs/**" ".claude/**" ".agents/**" "**/*.md" "**/*.mdx" "**/*.txt" ".gitignore" ".gitattributes")
mapfile -t extra < <(hook_list '.guardrails.ticketFreePaths')
ticket_free() { SDLC_PROJECT_DIR="$HOOK_PROJECT" sdlc_glob_any "$1" "${allowed[@]}" "${extra[@]+"${extra[@]}"}"; }
fix_hint="Pick an unblocked ticket with 'Status: ready-for-agent' (see ai-sdlc:sdlc-loop, stage 5) and write its id to $art_rel/ACTIVE_TICKET, or ask the user to do so."

case "$HOOK_TOOL" in
  Edit|Write|NotebookEdit)
    [ -n "$HOOK_FILE" ] || exit 0
    rel=$(hook_rel "$HOOK_FILE")
    ticket_free "$rel" && exit 0
    hook_deny "no active ticket: editing '$rel' is implementation work, and nothing is implemented without an accepted ticket. $fix_hint" ;;
  Bash|PowerShell)
    [ -n "$HOOK_CMD" ] || exit 0
    hook_cmd_scan "$HOOK_CMD"
    case "$HOOK_SCAN_CLASS" in
      readonly|verify|gitmeta|plugin) exit 0 ;;
    esac
    if [ -n "$HOOK_SCAN_OPAQUE" ]; then
      first=$(printf '%s' "$HOOK_SCAN_OPAQUE" | head -n1)
      hook_deny "no active ticket: '$first' runs a script, interpreter or tool whose file writes the guard cannot see, so it counts as implementation work. Read-only commands, the configured verify/lint commands, test runners and plugin scripts run without a ticket. $fix_hint"
    fi
    if [ "$HOOK_SCAN_DYNAMIC" = 1 ]; then
      hook_deny "no active ticket: the command writes to a target the guard cannot resolve statically (a variable, glob or unknown working directory). Name the file explicitly, or write the ticket id first. $fix_hint"
    fi
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      ticket_free "$t" && continue
      hook_deny "no active ticket: the command writes '$t', which is implementation work. Documentation, $art_rel/ and guardrails.ticketFreePaths stay writable. $fix_hint"
    done < <(hook_scan_targets_rel)
    exit 0 ;;
esac
exit 0
