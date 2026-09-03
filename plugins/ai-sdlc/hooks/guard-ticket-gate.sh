#!/usr/bin/env bash
# guard-ticket-gate.sh (PreToolUse: Edit|Write|NotebookEdit)
# Nothing is implemented without an accepted ticket. When guardrails.requireTicket is on
# (default from tier 2), source edits are denied until <artifacts>/ACTIVE_TICKET names the
# ticket being built. Documentation, specs, tickets, ADRs and the glossary stay editable so
# the earlier stages of the loop can run.
set -u
. "${0%/*}/../scripts/_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_hook.sh"

require=$(sdlc_config '.guardrails.requireTicket' '')
if [ -z "$require" ]; then tier=$(sdlc_config '.tier' 0); [ "${tier:-0}" -ge 2 ] 2>/dev/null && require=true || require=false; fi
[ "$require" = true ] || exit 0
[ -n "$HOOK_FILE" ] || exit 0
[ -s "$HOOK_ARTIFACTS/ACTIVE_TICKET" ] && exit 0

rel=$(hook_rel "$HOOK_FILE")
art_rel=$(hook_rel "$HOOK_ARTIFACTS")
allowed=("$art_rel/**" ".scratch/**" "docs/**" ".claude/**" ".agents/**" "**/*.md" "**/*.mdx" "**/*.txt" ".gitignore" ".gitattributes")
mapfile -t extra < <(hook_list '.guardrails.ticketFreePaths')
SDLC_PROJECT_DIR="$HOOK_PROJECT" sdlc_glob_any "$rel" "${allowed[@]}" "${extra[@]+"${extra[@]}"}" && exit 0

hook_deny "no active ticket: editing '$rel' is implementation work, and nothing is implemented without an accepted ticket. Pick an unblocked ticket with 'Status: ready-for-agent' (see ai-sdlc:sdlc-loop, stage 5) and write its id to $art_rel/ACTIVE_TICKET, or ask the user to do so."
