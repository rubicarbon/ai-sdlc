#!/usr/bin/env bash
# _common.sh — shared behaviour for every adapter script.
# Source order in an adapter: _root.sh, then this file (it sources _lib.sh and _project.sh).
#
# Provides:
#   out_json <json>            print the result unless dry-run
#   cli <cmd...>               run a platform CLI command (logged in mock/dry-run)
#   md_to_html <file>          Markdown -> HTML (awk, no external tool)
#   gh_repo                    owner/name for GitHub
#   az_context                 sets AZ_ORG, AZ_PROJECT, AZ_REPO and AZ_ARGS
#   require_gh / require_az    presence + authentication checks
#   iso_or_null <value>        JSON string or null
#   read_config <jq> <default>

. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"
SDLC_PROJECT_OPTIONAL=1 . "$SDLC_PLUGIN_ROOT/scripts/_project.sh"

: "${SDLC_PLATFORM:=unknown}"
SDLC_MOCKS="$SDLC_PLUGIN_ROOT/scripts/platform/_mocks"

# --dry-run = run against the bundled mocks and print the CLI commands that would run.
if [ "${SDLC_DRY_RUN:-0}" = "1" ]; then
  export SDLC_PLATFORM_MOCK=1
  if [ -z "${SDLC_MOCK_LOG:-}" ]; then
    SDLC_MOCK_LOG=$(mktemp "${TMPDIR:-/tmp}/ai-sdlc-dry.XXXXXX"); export SDLC_MOCK_LOG
    SDLC__OWN_LOG=1
  fi
  sdlc__dry_exit() { if [ -s "$SDLC_MOCK_LOG" ]; then while IFS= read -r l; do printf '+ %s\n' "$l"; done <"$SDLC_MOCK_LOG"; fi; [ "${SDLC__OWN_LOG:-0}" = 1 ] && rm -f "$SDLC_MOCK_LOG"; }
  trap sdlc__dry_exit EXIT
fi
if [ "${SDLC_PLATFORM_MOCK:-0}" = "1" ]; then
  case ":$PATH:" in *":$SDLC_MOCKS/bin:"*) ;; *) export PATH="$SDLC_MOCKS/bin:$PATH" ;; esac
  : "${SDLC_MOCK_STATE:=${TMPDIR:-/tmp}/ai-sdlc-mock-state}"; export SDLC_MOCK_STATE
fi

out_json() {
  # An empty result is an internal error: never exit 0 with nothing on stdout.
  [ -n "${1:-}" ] || sdlc_die 1 "internal error in ${0##*/}: empty result (a JSON step failed)"
  [ "${SDLC_DRY_RUN:-0}" = "1" ] || printf '%s\n' "$1"
}

cli() { "$@"; }

read_config() {  # read_config <jq path> [default]
  if [ -n "${SDLC_CONFIG:-}" ] && [ -f "$SDLC_CONFIG" ]; then sdlc_config "$1" "${2:-}"; else printf '%s' "${2:-}"; fi
}

iso_or_null() { if [ -n "${1:-}" ] && [ "$1" != "null" ]; then jq -cn --arg v "$1" '$v'; else printf 'null'; fi; }

md_to_html() { awk -f "$SDLC_PLUGIN_ROOT/scripts/platform/azure/_md2html.awk" "$1"; }

usage_die() { echo "ai-sdlc: usage: $*" >&2; exit 2; }

not_supported() { echo "ai-sdlc: not supported on this platform: $SDLC_PLATFORM $*" >&2; exit 3; }

# ---------------------------------------------------------------- GitHub
require_gh() {
  sdlc_has gh || sdlc_die 1 "GitHub CLI 'gh' not found. Install it from https://cli.github.com and run: gh auth login"
  gh auth status >/dev/null 2>&1 || sdlc_die 1 "GitHub CLI is not authenticated. Run: gh auth login (or set GH_TOKEN)"
}

gh_repo() {  # owner/name
  local owner name r
  owner=$(read_config '.repo.owner'); name=$(read_config '.repo.name')
  if [ -n "$owner" ] && [ -n "$name" ]; then printf '%s/%s' "$owner" "$name"; return 0; fi
  r=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) && [ -n "$r" ] && { printf '%s' "$r"; return 0; }
  r=$(git remote get-url origin 2>/dev/null) || sdlc_die 1 "cannot determine the GitHub repository (set repo.owner and repo.name in sdlc.config.json)"
  r="${r%.git}"; r="${r#*github.com[:/]}"; r="${r#*github.com/}"
  printf '%s' "$r"
}

gh_default_branch() {
  local b; b=$(read_config '.repo.defaultBranch')
  [ -n "$b" ] && { printf '%s' "$b"; return; }
  gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || printf 'main'
}

# ---------------------------------------------------------------- Azure DevOps
require_az() {
  sdlc_has az || sdlc_die 1 "Azure CLI 'az' not found. Install it from https://aka.ms/azure-cli, then: az extension add --name azure-devops"
  az extension show --name azure-devops >/dev/null 2>&1 || sdlc_die 1 "Azure DevOps CLI extension missing. Run: az extension add --name azure-devops"
  if [ -z "${AZURE_DEVOPS_EXT_PAT:-}" ]; then
    az account show >/dev/null 2>&1 || sdlc_die 1 "Azure CLI is not logged in. Run: az login (or export AZURE_DEVOPS_EXT_PAT=<pat>)"
  fi
}

# az_context: AZ_ORG (https://dev.azure.com/org), AZ_PROJECT, AZ_REPO, AZ_ARGS (array)
az_context() {
  AZ_ORG=$(read_config '.azure.organization'); AZ_PROJECT=$(read_config '.azure.project'); AZ_REPO=$(read_config '.azure.repo')
  if [ -z "$AZ_ORG" ] || [ -z "$AZ_PROJECT" ] || [ -z "$AZ_REPO" ]; then
    local r; r=$(git remote get-url origin 2>/dev/null || true)
    case "$r" in
      https://*dev.azure.com/*/*/_git/*)
        r="${r#https://}"; r="${r#*@}"; r="${r#dev.azure.com/}"
        : "${AZ_ORG:=https://dev.azure.com/${r%%/*}}"; r="${r#*/}"
        : "${AZ_PROJECT:=${r%%/_git/*}}"; : "${AZ_REPO:=${r##*/_git/}}" ;;
      https://*.visualstudio.com/*/_git/*)
        r="${r#https://}"; r="${r#*@}"
        : "${AZ_ORG:=https://dev.azure.com/${r%%.visualstudio.com*}}"; r="${r#*.visualstudio.com/}"
        : "${AZ_PROJECT:=${r%%/_git/*}}"; : "${AZ_REPO:=${r##*/_git/}}" ;;
      *ssh.dev.azure.com:v3/*)
        r="${r#*ssh.dev.azure.com:v3/}"
        : "${AZ_ORG:=https://dev.azure.com/${r%%/*}}"; r="${r#*/}"
        : "${AZ_PROJECT:=${r%%/*}}"; : "${AZ_REPO:=${r##*/}}" ;;
    esac
  fi
  [ -n "$AZ_ORG" ] && [ -n "$AZ_PROJECT" ] && [ -n "$AZ_REPO" ] || sdlc_die 1 "cannot determine Azure DevOps organization/project/repo (set azure.organization, azure.project, azure.repo in sdlc.config.json)"
  AZ_REPO="${AZ_REPO%.git}"
  AZ_ARGS=(--org "$AZ_ORG" --project "$AZ_PROJECT")
  export AZ_ORG AZ_PROJECT AZ_REPO
}

# az_work_item_type: configured, else derived from the process template
az_work_item_type() {
  local t; t=$(read_config '.azure.workItemType')
  [ -n "$t" ] && { printf '%s' "$t"; return; }
  local tpl; tpl=$(az devops project show --project "$AZ_PROJECT" --org "$AZ_ORG" -o tsv --query capabilities.processTemplate.templateName 2>/dev/null || true)
  case "$tpl" in
    Scrum*) printf 'Product Backlog Item' ;;
    Basic*) printf 'Issue' ;;
    CMMI*) printf 'Requirement' ;;
    *) printf 'User Story' ;;
  esac
}

# az_state: map Azure states to open/closed
az_state() {
  case "$1" in Closed|Done|Removed|Resolved|Completed) printf 'closed' ;; *) printf 'open' ;; esac
}

# az_repo_id / az_repo_web_url
az_repo_json() { az repos show --repository "$AZ_REPO" "${AZ_ARGS[@]}" -o json; }
