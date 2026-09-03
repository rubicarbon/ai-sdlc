#!/usr/bin/env bash
# _hook.sh — shared prologue for every plugin hook. Source after _root.sh:
#
#   . "${0%/*}/../scripts/_root.sh" || exit 2
#   . "$SDLC_PLUGIN_ROOT/scripts/_hook.sh"
#
# 1. Sources _project.sh, which exits 0 immediately (builtins only, no jq) when the
#    working directory is not an sdlc project. Plugin hooks fire in every session, in
#    every project: silence outside sdlc projects is the contract.
# 2. Reads the hook JSON once and exposes HOOK_TOOL, HOOK_CWD, HOOK_FILE (file_path or
#    notebook_path), HOOK_PATH (Glob/Grep path), HOOK_CMD, HOOK_AGENT, HOOK_EVENT.
#    Unparseable input denies (exit 2) unless HOOK_FAIL_OPEN=1 was set before sourcing.
# 3. Provides hook_deny, hook_rel, hook_cmd_paths, hook_list, hook_cmd_writes, hook_home.

. "$SDLC_PLUGIN_ROOT/scripts/_project.sh"
. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"
. "$SDLC_PLUGIN_ROOT/scripts/_glob.sh"

hook_deny() {  # hook_deny <message> : block the tool call with a reason Claude can act on
  echo "ai-sdlc guardrail: $1" >&2
  exit 2
}

IFS= read -r -d '' HOOK_INPUT || true
if ! HOOK__PARSED=$(jq -r '@sh "HOOK_TOOL=\(.tool_name // "") HOOK_CWD=\(.cwd // "") HOOK_FILE=\(.tool_input.file_path // .tool_input.notebook_path // "") HOOK_PATH=\(.tool_input.path // "") HOOK_CMD=\(.tool_input.command // "") HOOK_AGENT=\(.agent_type // "") HOOK_EVENT=\(.hook_event_name // "")"' <<<"$HOOK_INPUT" 2>/dev/null) || [ -z "$HOOK__PARSED" ]; then
  if [ "${HOOK_FAIL_OPEN:-0}" = 1 ]; then exit 0; fi
  hook_deny "${0##*/} received input that is not valid hook JSON; refusing to guess"
fi
eval "$HOOK__PARSED"
unset HOOK__PARSED

HOOK_PROJECT=$(sdlc_norm_path "$SDLC_PROJECT_DIR")
HOOK_ARTIFACTS=$(sdlc_artifacts_dir)
hook_home() { sdlc_norm_path "${HOME:-${USERPROFILE:-}}"; }

# hook_rel <path> : project-relative with forward slashes (absolute if outside the project)
hook_rel() {
  local p; p=$(sdlc_norm_path "$1")
  case "$p" in /*|//*) ;; *) p="$(sdlc_norm_path "${HOOK_CWD:-$PWD}")/$p" ;; esac
  case "${p,,}" in "${HOOK_PROJECT,,}"/*) printf '%s' "${p:$(( ${#HOOK_PROJECT} + 1 ))}" ;; *) printf '%s' "$p" ;; esac
}

# hook_list <jq path> [default...] : config array as lines, defaults when absent
hook_list() {
  local q="$1"; shift
  local v; v=$(jq -r "$q // empty | .[]?" "$SDLC_CONFIG" 2>/dev/null)
  if [ -n "$v" ]; then printf '%s\n' "$v"; else printf '%s\n' "$@"; fi
}

# hook_cmd_paths <command> : path-like tokens of a shell command, one per line
hook_cmd_paths() {
  local cmd="$1" nl=$'\n' seg t br='[(){}]'
  cmd="${cmd//&&/$nl}"; cmd="${cmd//||/$nl}"; cmd="${cmd//;/$nl}"; cmd="${cmd//|/$nl}"; cmd="${cmd//\$(/$nl}"; cmd="${cmd//\`/$nl}"; cmd="${cmd//$br/$nl}"
  while IFS= read -r seg; do
    seg="${seg//\"/}"; seg="${seg//\'/}"
    set -f; local -a toks=($seg); set +f
    for t in "${toks[@]+"${toks[@]}"}"; do
      t="${t#[0-9]}"; t="${t##[<>]}"; t="${t##[<>]}"; t="${t#&}"
      case "$t" in --*=*|-[A-Za-z]=*|[A-Za-z_]*=*) t="${t#*=}" ;; esac
      [ -z "$t" ] && continue
      case "$t" in *://*|/dev/*|-*) continue ;; esac
      # every remaining token may name a file (a bare `CODEOWNERS` or `.env` included);
      # command words like `rm` simply match no glob
      t="${t/#\$HOME/$(hook_home)}"; t="${t/#\$USERPROFILE/$(hook_home)}"; t="${t/#\~/$(hook_home)}"
      printf '%s\n' "$t"
    done
  done <<<"$cmd"
}

# hook_cmd_writes <command> : exit 0 when the command can modify files
hook_cmd_writes() {
  local c="$1"
  local re='(^|[[:space:];&|(`]|[[:space:]])(rm|mv|cp|tee|touch|truncate|install|ln|mkdir|rmdir|dd|chmod|chown|shred|patch|sed[[:space:]]+(-[a-zA-Z]*i|--in-place)|perl[[:space:]]+-[a-zA-Z]*i|python[3]?[[:space:]]+-c|git[[:space:]]+(add|commit|push|checkout|switch|restore|reset|stash|rebase|merge|cherry-pick|rm|mv|clean|apply|am|tag|branch[[:space:]]+-[dDm]|worktree|filter-branch|update-ref)|npm[[:space:]]+(i|install|ci|update|uninstall|link|publish)|pnpm[[:space:]]+(add|install|remove)|yarn[[:space:]]+(add|remove)|pip[3]?[[:space:]]+(install|uninstall)|Set-Content|Add-Content|Out-File|Remove-Item|Move-Item|Copy-Item|New-Item|Rename-Item|Clear-Content)([[:space:]]|$)'
  [[ "$c" =~ $re ]] && return 0
  # redirections other than to /dev/null or fd duplication
  local stripped="${c//2>&1/}"; stripped="${stripped//>\/dev\/null/}"; stripped="${stripped//> \/dev\/null/}"; stripped="${stripped//&>\/dev\/null/}"
  [[ "$stripped" =~ (^|[^\>\<])\>[^\>]|\>\> ]] && return 0
  return 1
}
