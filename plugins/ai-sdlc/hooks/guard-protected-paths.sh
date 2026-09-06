#!/usr/bin/env bash
# guard-protected-paths.sh (PreToolUse: Edit|Write|NotebookEdit|Bash|PowerShell)
# Denies modification of the paths listed in guardrails.protectedPaths (nothing unless the
# project configures some) and, always, of the release-authorisation markers under the artifacts
# directory: <artifacts>/UNLOCK_PROTECTED and <artifacts>/release/**. Reads stay allowed.
# A human unlocks a one-off change to a configured path by creating <artifacts>/UNLOCK_PROTECTED;
# the marker never unlocks the markers themselves, so the agent cannot create it or write a
# release authorisation. Delete the marker afterwards.
set -u
. "${0%/*}/../scripts/_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_hook.sh"

patterns=()
[ -e "$HOOK_ARTIFACTS/UNLOCK_PROTECTED" ] || mapfile -t patterns < <(hook_list '.guardrails.protectedPaths')
art_rel=$(hook_rel "$HOOK_ARTIFACTS")
patterns+=("$art_rel/UNLOCK_PROTECTED" "$art_rel/release/**")

is_protected() { SDLC_PROJECT_DIR="$HOOK_PROJECT" sdlc_glob_any "$(hook_rel "$1")" "${patterns[@]}"; }

case "$HOOK_TOOL" in
  Edit|Write|NotebookEdit)
    [ -n "$HOOK_FILE" ] && is_protected "$HOOK_FILE" && hook_deny "'$(hook_rel "$HOOK_FILE")' is a protected path (guardrails.protectedPaths or a release-authorisation marker). Propose the change in the PR description for a human to apply, or ask them to create $art_rel/UNLOCK_PROTECTED for this one edit." ;;
  Bash|PowerShell)
    [ -n "$HOOK_CMD" ] || exit 0
    hook_cmd_writes "$HOOK_CMD" || exit 0
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      is_protected "$t" && hook_deny "the command modifies protected path '$(hook_rel "$t")' (guardrails.protectedPaths or a release-authorisation marker). Reads are fine; changes need a human."
    done < <(hook_cmd_paths "$HOOK_CMD") ;;
esac
exit 0
