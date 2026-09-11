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

# cli_json <label> <cmd...>: run a platform CLI command whose stdout must be JSON.
# A non-zero exit or non-JSON output ends the adapter with exit 1 and a message that
# names <label> (the command text without secrets) and the CLI's first stderr line.
# A failure is never turned into an empty result. Because callers capture the output
# with $(...), they must append `|| exit $?` so the die propagates out of the subshell.
cli_json() {
  local label="$1"; shift
  local errf out rc first
  errf=$(sdlc_tmpfile .err)
  out=$("$@" 2>"$errf"); rc=$?
  first=$(head -n1 "$errf" 2>/dev/null); rm -f "$errf"
  [ $rc -eq 0 ] || sdlc_die 1 "$label failed (exit $rc): ${first:-no error output}"
  if [ -z "$out" ] || ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    sdlc_die 1 "$label returned invalid JSON: ${out:0:120}"
  fi
  printf '%s' "$out"
}

# json_list <items...> -> JSON array of the non-empty strings (no items -> [])
json_list() { printf '%s\n' "$@" | jq -R . | jq -cs 'map(select(length>0))'; }

# pr_checks_result <id> <platform> <checks-json> <required-json> -> the normalised pr_checks
# object. The rules are identical on every platform and never pass with zero checks:
#   any fail -> fail; else any pending -> pending; else no checks -> fail (fail closed);
#   else a required name absent or only skipped -> fail; else nothing passed -> fail;
#   else pass. A check named "<Type> (<name>)" satisfies the required name <name>.
pr_checks_result() {
  jq -cn --arg id "$1" --arg p "$2" --argjson c "$3" --argjson req "$4" '
    def satisfies($r): .name == $r or (.name | endswith(" (" + $r + ")"));
    ([$c[] | select(.status=="fail") | .name]) as $failed
    | ([$c[] | select(.status=="pending") | .name]) as $pend
    | ([$req[] | . as $r | select(any($c[]; satisfies($r) and .status=="pass") | not)]) as $missing
    | (if ($failed|length) > 0 then {status:"fail", reason:("failing checks: " + ($failed|join(", ")))}
       elif ($pend|length) > 0 then {status:"pending", reason:("pending checks: " + ($pend|join(", ")))}
       elif ($c|length) == 0 then {status:"fail", reason:"no checks reported on the pull request (checks not configured or not started yet): failing closed, re-run later"}
       elif ($missing|length) > 0 then {status:"fail", reason:("required checks missing or skipped: " + ($missing|join(", ")))}
       elif (any($c[]; .status=="pass") | not) then {status:"fail", reason:"every check was skipped"}
       else {status:"pass", reason:null} end) as $v
    | {id:$id, status:$v.status, checks:$c, required:$req, reason:$v.reason, platform:$p}'
}

# pr_checks_exit <result-json>: exit 0 pass, 8 pending, 1 fail.
pr_checks_exit() {
  case "$(printf '%s' "$1" | jq -r .status)" in pass) exit 0 ;; pending) exit 8 ;; *) exit 1 ;; esac
}

# config_array <jq path> -> the configured JSON array, or [] when unset or not an array
config_array() {
  local v; v=$(read_config "$1" '[]')
  if printf '%s' "$v" | jq -e 'type=="array"' >/dev/null 2>&1; then printf '%s' "$v"; else printf '[]'; fi
}

# sdlc_reverts_scan <since> <until>: sets REVERTS_JSON (revert commits from the local git
# log), REVERTS_SOURCE ("configured" or "partial") and REVERTS_WARNING. The history is
# partial when the clone is shallow, has no commit older than <since>, or cannot be read.
# shellcheck disable=SC2034 # These globals are the function's documented outputs for adapters.
sdlc_reverts_scan() {
  local since="$1" until="$2" log sha date body target
  REVERTS_JSON='[]'; REVERTS_SOURCE=configured; REVERTS_WARNING=""
  if ! log=$(git log --since="$since" --until="${until}T23:59:59" --grep='^Revert' \
      --format='%H%x1f%cI%x1f%b%x1e' 2>/dev/null); then
    REVERTS_SOURCE=partial
    REVERTS_WARNING="git log failed in $(pwd): reverts were not scanned"
    return 0
  fi
  while IFS=$'\x1f' read -r sha date body; do
    [ -n "$sha" ] || continue
    target=$(printf '%s' "$body" | grep -oE 'reverts commit [0-9a-f]{7,40}' | head -n1 | awk '{print $3}')
    REVERTS_JSON=$(printf '%s' "$REVERTS_JSON" | jq -c --arg sha "$sha" --arg d "$date" --arg t "${target:-}" \
      '. + [{sha:$sha, committed_at:$d, reverts_sha:(if $t=="" then null else $t end)}]')
  done < <(printf '%s' "$log" | tr -d '\n' | tr '\036' '\n')
  if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
    REVERTS_SOURCE=partial
    REVERTS_WARNING="local git history is shallow: reverts older than the clone depth are not visible"
  elif [ -z "$(git rev-list -n1 --before="${since}T00:00:00" HEAD 2>/dev/null)" ]; then
    REVERTS_SOURCE=partial
    REVERTS_WARNING="local git history has no commit older than $since: reverts before the earliest local commit are not visible"
  fi
}

read_config() {  # read_config <jq path> [default]
  if [ -n "${SDLC_CONFIG:-}" ] && [ -f "$SDLC_CONFIG" ]; then sdlc_config "$1" "${2:-}"; else printf '%s' "${2:-}"; fi
}

# Two rules for the pull-request review, shared by init, the adapters and pr_checks:
#   review_runner        -> ci | local (review.runner, default ci). Decides whether the review
#                           workflow/pipeline (sdlc-pr-review.yml, and sdlc-cost-report.yml on
#                           GitHub) is rendered, installed and registered at all.
#   review_pipeline_name -> the Azure build pipeline that pr_checks requires and
#                           branch_protect_apply enforces as a build policy: azure.pipelineName
#                           when set (a custom build requirement, whatever the runner), else
#                           sdlc-pr-review for runner ci, else nothing (empty).
review_runner() { local r; r=$(read_config '.review.runner' ci); case "$r" in local) printf 'local' ;; *) printf 'ci' ;; esac; }
review_pipeline_name() {
  local n; n=$(read_config '.azure.pipelineName' '')
  if [ -n "$n" ]; then printf '%s' "$n"; elif [ "$(review_runner)" = ci ]; then printf 'sdlc-pr-review'; fi
}
# review_is_workflow <file name>: the CI files that belong to the review runner
review_is_workflow() { case "$1" in sdlc-pr-review.yml|sdlc-cost-report.yml) return 0 ;; *) return 1 ;; esac; }

# migration_remote_done: after branch_protect_apply succeeded for real (not a dry run), record
# in <artifacts>/migrations.json that the remote side reflects the current review runner.
migration_remote_done() {
  [ "${SDLC_DRY_RUN:-0}" = 1 ] && return 0
  [ -n "${SDLC_PROJECT_DIR:-}" ] || return 0
  local f; f="$(sdlc_artifacts_dir)/migrations.json"
  [ -f "$f" ] || return 0
  jq -e '.["review-runner"].remote == "pending"' "$f" >/dev/null 2>&1 || return 0
  local tmp; tmp=$(sdlc_tmpfile .json)
  jq --arg at "$(sdlc_iso_now)" '.["review-runner"].remote = "done" | .["review-runner"].remote_at = $at' "$f" >"$tmp" && mv "$tmp" "$f"
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
