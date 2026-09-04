#!/usr/bin/env bash
# guard-secrets.sh (PreToolUse: Read|Glob|Grep|Edit|Write|NotebookEdit|Bash|PowerShell)
# Denies access to secret material: .env files (except .env.example/.env.sample/.env.template),
# secrets/**, private keys, ~/.ssh, ~/.aws, ~/.azure, ~/.config/gh, plus guardrails.secretPaths.
# The permission deny rules rendered into .claude/settings.json cover the same paths for the
# file tools; this hook adds Bash/PowerShell coverage and the config-driven list.
set -u
. "${0%/*}/../scripts/_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_hook.sh"

defaults=(".env" ".env.*" "secrets/**" "**/*.pem" "**/id_rsa*" "**/id_ed25519*" "**/*.p12" "**/*.pfx" "**/credentials.json" "**/service-account*.json")
# shellcheck disable=SC2088 # These are literal user-facing tilde patterns, expanded by is_secret.
home_defaults=("~/.ssh/**" "~/.aws/**" "~/.azure/**" "~/.config/gh/**" "~/.kube/config" "~/.netrc" "~/.npmrc" "~/.docker/config.json")
mapfile -t patterns < <(hook_list '.guardrails.secretPaths' "${defaults[@]}")
home=$(hook_home)

is_secret() {  # is_secret <path> : 0 when the path is secret material
  local p="$1" rel base h
  p=$(sdlc_norm_path "$p")
  base="${p##*/}"
  case "$base" in .env.example|.env.sample|.env.template|.env.dist) return 1 ;; esac
  for h in "${home_defaults[@]}"; do
    if [ -n "$home" ] && sdlc_glob_match "/${h#\~/}" "${p#"$home"/}" && [[ "${p,,}" == "${home,,}/"* ]]; then return 0; fi
  done
  rel=$(hook_rel "$p")
  SDLC_PROJECT_DIR="$HOOK_PROJECT" sdlc_glob_any "$rel" "${patterns[@]}"
}

check() { is_secret "$1" && hook_deny "'$1' is secret material (matched the secret path list). Read it yourself; the agent never does."; }

case "$HOOK_TOOL" in
  Read|Edit|Write|NotebookEdit) [ -n "$HOOK_FILE" ] && check "$HOOK_FILE" ;;
  Glob|Grep) [ -n "$HOOK_PATH" ] && check "$HOOK_PATH" ;;
  Bash|PowerShell)
    [ -n "$HOOK_CMD" ] || exit 0
    while IFS= read -r t; do [ -n "$t" ] && check "$t"; done < <(hook_cmd_paths "$HOOK_CMD")
    # env-var shortcuts to credential files
    if [[ "$HOOK_CMD" =~ (AWS_SHARED_CREDENTIALS_FILE|GITHUB_TOKEN=|GH_TOKEN=|AZURE_DEVOPS_EXT_PAT=|\.netrc|id_rsa|id_ed25519) ]] && [[ "$HOOK_CMD" =~ (cat|less|more|head|tail|type|Get-Content|echo|printf|base64|xxd|cp|scp|curl) ]]; then
      hook_deny "the command reads or exfiltrates credential material; not allowed for the agent"
    fi ;;
esac
exit 0
