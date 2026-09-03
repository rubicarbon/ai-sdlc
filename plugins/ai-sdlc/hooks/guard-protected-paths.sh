#!/usr/bin/env bash
# guard-protected-paths.sh (PreToolUse: Edit|Write|NotebookEdit|Bash|PowerShell)
# Denies modification of the paths listed in guardrails.protectedPaths (CI workflows, CODEOWNERS,
# sdlc.config.json, .claude/settings.json, lockfiles by default). Reads stay allowed.
# A human unlocks a one-off change by creating <artifacts>/UNLOCK_PROTECTED (the marker is
# itself protected, so the agent cannot create it); delete the marker afterwards.
set -u
. "${0%/*}/../scripts/_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_hook.sh"

[ -e "$HOOK_ARTIFACTS/UNLOCK_PROTECTED" ] && exit 0

defaults=(".github/workflows/**" ".azuredevops/**" "CODEOWNERS" "sdlc.config.json" ".claude/settings.json" "package-lock.json" "pnpm-lock.yaml" "yarn.lock" "Cargo.lock" "poetry.lock" "go.sum")
mapfile -t patterns < <(hook_list '.guardrails.protectedPaths' "${defaults[@]}")
art_rel=$(hook_rel "$HOOK_ARTIFACTS")
patterns+=("$art_rel/UNLOCK_PROTECTED" "$art_rel/release/**")

is_protected() { SDLC_PROJECT_DIR="$HOOK_PROJECT" sdlc_glob_any "$(hook_rel "$1")" "${patterns[@]}"; }

case "$HOOK_TOOL" in
  Edit|Write|NotebookEdit)
    [ -n "$HOOK_FILE" ] && is_protected "$HOOK_FILE" && hook_deny "'$(hook_rel "$HOOK_FILE")' is a protected path (guardrails.protectedPaths). Propose the change in the PR description for a human to apply, or ask them to create $art_rel/UNLOCK_PROTECTED for this one edit." ;;
  Bash|PowerShell)
    [ -n "$HOOK_CMD" ] || exit 0
    hook_cmd_writes "$HOOK_CMD" || exit 0
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      is_protected "$t" && hook_deny "the command modifies protected path '$(hook_rel "$t")' (guardrails.protectedPaths). Reads are fine; changes need a human."
    done < <(hook_cmd_paths "$HOOK_CMD") ;;
esac
exit 0
