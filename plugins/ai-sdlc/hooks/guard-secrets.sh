#!/usr/bin/env bash
# guard-secrets.sh (PreToolUse: Read|Glob|Grep|Edit|Write|NotebookEdit|Bash|PowerShell)
# Denies access to secret material. Two layers cover it, with different reach:
#   - this hook sees every tool call (file tools, Glob/Grep, Bash, PowerShell) but not @file
#     mentions; it applies guardrails.secretPaths (absent: the defaults below, with an exemption
#     for .env.example/.env.sample/.env.template/.env.dist; []: nothing; a list: exactly those
#     globs, no exemption) plus the fixed home-directory credential paths;
#   - the permission deny rules rendered into .claude/settings.json see file tools and @file
#     mentions but not the shell; they list the same names as the defaults below, one by one.
# guardrails.secretPaths configures this hook only; the deny list is edited in settings.json.
set -u
. "${0%/*}/../scripts/_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_hook.sh"

defaults=(".env" ".env.*" "secrets/**" "**/*-key.pem" "**/*.key.pem" "**/privkey.pem" "**/*.key" "**/id_rsa" "**/id_ed25519" "**/id_ecdsa" "**/*.p12" "**/*.pfx" "**/credentials.json" "**/service-account*.json")
# shellcheck disable=SC2088 # These are literal user-facing tilde patterns, expanded by is_secret.
home_defaults=("~/.ssh/**" "~/.aws/**" "~/.azure/**" "~/.config/gh/**" "~/.kube/config" "~/.netrc" "~/.npmrc" "~/.docker/config.json")
# one jq call: the first line says where the project list comes from, the rest are its globs
mapfile -t configured < <(jq -r 'if (.guardrails.secretPaths | type) == "array" then "configured", .guardrails.secretPaths[] else "default" end' "$SDLC_CONFIG" 2>/dev/null)
list_source="${configured[0]:-default}"
if [ "$list_source" = configured ]; then patterns=("${configured[@]:1}"); else patterns=("${defaults[@]}"); fi
home=$(hook_home)

is_secret() {  # is_secret <path> : 0 when the path is secret material
  local p="$1" rel base h
  p=$(sdlc_norm_path "$p")
  base="${p##*/}"
  for h in "${home_defaults[@]}"; do
    if [ -n "$home" ] && sdlc_glob_match "/${h#\~/}" "${p#"$home"/}" && [[ "${p,,}" == "${home,,}/"* ]]; then return 0; fi
  done
  # example files are exempt from the defaults only; a configured list is applied literally
  if [ "$list_source" = default ]; then case "$base" in .env.example|.env.sample|.env.template|.env.dist) return 1 ;; esac; fi
  rel=$(hook_rel "$p")
  SDLC_PROJECT_DIR="$HOOK_PROJECT" sdlc_glob_any "$rel" "${patterns[@]+"${patterns[@]}"}"
}

check() { is_secret "$1" && hook_deny "'$1' is secret material (matched the secret path list). Read it yourself; the agent never does."; }

case "$HOOK_TOOL" in
  Read|Edit|Write|NotebookEdit) [ -n "$HOOK_FILE" ] && check "$HOOK_FILE" ;;
  Glob|Grep) [ -n "$HOOK_PATH" ] && check "$HOOK_PATH" ;;
  Bash|PowerShell)
    [ -n "$HOOK_CMD" ] || exit 0
    while IFS= read -r t; do [ -n "$t" ] && check "$t"; done < <(hook_cmd_paths "$HOOK_CMD")
    # env-var shortcuts to credential files (key names need a boundary, so id_rsa.pub passes)
    if [[ "$HOOK_CMD" =~ (AWS_SHARED_CREDENTIALS_FILE|GITHUB_TOKEN=|GH_TOKEN=|AZURE_DEVOPS_EXT_PAT=|\.netrc|(^|[^A-Za-z0-9_.])(id_rsa|id_ed25519|id_ecdsa)([^A-Za-z0-9_.]|$)) ]] && [[ "$HOOK_CMD" =~ (cat|less|more|head|tail|type|Get-Content|echo|printf|base64|xxd|cp|scp|curl) ]]; then
      hook_deny "the command reads or exfiltrates credential material; not allowed for the agent"
    fi ;;
esac
exit 0
