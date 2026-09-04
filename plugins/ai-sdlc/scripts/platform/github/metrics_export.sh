#!/usr/bin/env bash
# metrics_export (GitHub): merged PRs, deployments, incidents and reverts -> normalised JSON.
#   metrics_export <since> <until> <out.json>      (dates: YYYY-MM-DD, UTC)
# Every CLI call must succeed and return JSON; a failure ends the export with exit 1 and
# no output file (the file is assembled in a temp location and moved at the end). The
# file records where each series came from ("sources") and any coverage caveats
# ("warnings"). Under --dry-run nothing is written.
set -u
export SDLC_PLATFORM=github
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
since="${1:-}"; until="${2:-}"; out="${3:-}"
[[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && "$until" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [ -n "$out" ] \
  || usage_die "metrics_export <since YYYY-MM-DD> <until YYYY-MM-DD> <out.json>"
require_gh
repo=$(gh_repo)
incident_label=$(read_config '.metrics.incidentLabel' 'incident')
deploy_workflow=$(read_config '.github.deployWorkflow' '')
deploy_env=$(read_config '.metrics.deployEnvironment' 'production')
since_ts="${since}T00:00:00Z"; until_ts="${until}T23:59:59Z"
warnings=()

raw_prs=$(cli_json "gh pr list --repo $repo --state merged" gh pr list --repo "$repo" --state merged \
  --search "merged:$since..$until" --limit 500 \
  --json number,title,createdAt,mergedAt,additions,deletions,changedFiles,author,reviews,commits) || exit $?
prs=$(printf '%s' "$raw_prs" | jq -c '[.[] | {
  id: (.number|tostring), created_at: .createdAt, merged_at: .mergedAt,
  first_review_at: ([(.reviews // [])[] | .submittedAt] | min),
  additions, deletions, changed_files: .changedFiles,
  first_commit_at: ([(.commits // [])[] | .committedDate] | min),
  author: (.author.login // null), is_revert: ((.title // "") | startswith("Revert"))}]') \
  || sdlc_die 1 "gh pr list returned an unexpected shape"

# Deployments: the configured deploy workflow's runs, else the Deployments API (always
# available on GitHub, so the source is always "configured").
if [ -n "$deploy_workflow" ]; then
  runs=$(cli_json "gh run list --repo $repo --workflow $deploy_workflow" gh run list --repo "$repo" \
    --workflow "$deploy_workflow" --limit 200 --json databaseId,conclusion,createdAt,updatedAt,headSha) || exit $?
  deployments=$(printf '%s' "$runs" | jq -c --arg s "$since_ts" --arg u "$until_ts" --arg env "$deploy_env" '
    [.[] | select(.createdAt >= $s and .createdAt <= $u) | {
      id: (.databaseId|tostring), environment: $env, started_at: .createdAt, finished_at: .updatedAt,
      status: (if .conclusion=="success" then "success" elif .conclusion==null then "pending" else "failure" end),
      sha: .headSha}]') || sdlc_die 1 "gh run list returned an unexpected shape"
else
  deps_raw=$(cli_json "gh api repos/$repo/deployments?environment=$deploy_env" gh api --paginate \
    "repos/$repo/deployments?environment=$deploy_env&per_page=100") || exit $?
  deps=$(printf '%s' "$deps_raw" | jq -cs 'add // []')
  deployments='[]'
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    did=$(printf '%s' "$d" | jq -r .id)
    st_raw=$(cli_json "gh api repos/$repo/deployments/$did/statuses" gh api \
      "repos/$repo/deployments/$did/statuses?per_page=1") || exit $?
    st=$(printf '%s' "$st_raw" | jq -r '.[0].state // "pending"')
    deployments=$(printf '%s' "$deployments" | jq -c --argjson d "$d" --arg st "$st" --arg env "$deploy_env" '
      . + [{id: ($d.id|tostring), environment: $env, started_at: $d.created_at, finished_at: $d.updated_at,
            status: (if $st=="success" then "success"
                     elif $st=="pending" or $st=="in_progress" or $st=="queued" then "pending" else "failure" end),
            sha: $d.sha}]')
  done < <(printf '%s' "$deps" | jq -c --arg s "$since_ts" --arg u "$until_ts" '.[] | select(.created_at >= $s and .created_at <= $u)')
fi

issues=$(cli_json "gh issue list --repo $repo --label $incident_label" gh issue list --repo "$repo" \
  --label "$incident_label" --state all --limit 200 --json number,createdAt,closedAt,labels) || exit $?
incidents=$(printf '%s' "$issues" | jq -c --arg s "$since_ts" --arg u "$until_ts" '
  [.[] | select(.createdAt <= $u and (.createdAt >= $s or (.closedAt // "9999") >= $s))
   | {id: (.number|tostring), opened_at: .createdAt, closed_at: .closedAt, labels: [(.labels // [])[] | .name]}]') \
  || sdlc_die 1 "gh issue list returned an unexpected shape"

sdlc_reverts_scan "$since" "$until"
[ -n "$REVERTS_WARNING" ] && warnings+=("$REVERTS_WARNING")

doc=$(jq -cn --arg repo "$repo" --arg s "$since" --arg u "$until" --arg now "$(sdlc_iso_now)" --arg rev_src "$REVERTS_SOURCE" \
  --argjson prs "$prs" --argjson dep "$deployments" --argjson inc "$incidents" --argjson rev "$REVERTS_JSON" \
  --argjson warn "$(json_list "${warnings[@]+"${warnings[@]}"}")" \
  '{platform:"github", repo:$repo, since:$s, until:$u, exported_at:$now,
    sources:{prs:"configured", deployments:"configured", incidents:"configured", reverts:$rev_src},
    warnings:$warn, prs:$prs, deployments:$dep, incidents:$inc, reverts:$rev}')
if [ "${SDLC_DRY_RUN:-0}" != "1" ]; then
  tmp=$(sdlc_tmpfile .json); printf '%s\n' "$doc" >"$tmp"
  case "$out" in */*) mkdir -p "${out%/*}" ;; esac
  mv "$tmp" "$out" || { rm -f "$tmp"; sdlc_die 1 "cannot write $out"; }
fi
out_json "$(printf '%s' "$doc" | jq -c --arg out "$out" '{prs:(.prs|length), deployments:(.deployments|length),
  incidents:(.incidents|length), reverts:(.reverts|length), out:$out, warnings:.warnings, platform:"github"}')"
