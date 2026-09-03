#!/usr/bin/env bash
# metrics_export (GitHub): merged PRs, deployments, incidents and reverts -> normalised JSON.
#   metrics_export <since> <until> <out.json>      (dates: YYYY-MM-DD, UTC)
set -u
export SDLC_PLATFORM=github
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
since="${1:-}"; until="${2:-}"; out="${3:-}"
[[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && "$until" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [ -n "$out" ] || usage_die "metrics_export <since YYYY-MM-DD> <until YYYY-MM-DD> <out.json>"
require_gh
repo=$(gh_repo)
incident_label=$(read_config '.metrics.incidentLabel' 'incident')
deploy_workflow=$(read_config '.github.deployWorkflow' '')
deploy_env=$(read_config '.metrics.deployEnvironment' 'production')
since_ts="${since}T00:00:00Z"; until_ts="${until}T23:59:59Z"

prs=$(cli gh pr list --repo "$repo" --state merged --search "merged:$since..$until" --limit 500 \
  --json number,title,createdAt,mergedAt,additions,deletions,changedFiles,author,reviews,commits 2>/dev/null) || prs='[]'
prs=$(printf '%s' "$prs" | jq -c '[.[] | {
  id: (.number|tostring), created_at: .createdAt, merged_at: .mergedAt,
  first_review_at: ([(.reviews // [])[] | .submittedAt] | min),
  additions, deletions, changed_files: .changedFiles,
  first_commit_at: ([(.commits // [])[] | .committedDate] | min),
  author: (.author.login // null), is_revert: ((.title // "") | startswith("Revert"))}]')

if [ -n "$deploy_workflow" ]; then
  runs=$(cli gh run list --repo "$repo" --workflow "$deploy_workflow" --limit 200 --json databaseId,conclusion,createdAt,updatedAt,headSha 2>/dev/null) || runs='[]'
  deployments=$(printf '%s' "$runs" | jq -c --arg s "$since_ts" --arg u "$until_ts" --arg env "$deploy_env" '[.[] | select(.createdAt >= $s and .createdAt <= $u) | {
    id: (.databaseId|tostring), environment: $env, started_at: .createdAt, finished_at: .updatedAt,
    status: (if .conclusion=="success" then "success" elif .conclusion==null then "pending" else "failure" end), sha: .headSha}]')
else
  deps=$(cli gh api --paginate "repos/$repo/deployments?environment=$deploy_env&per_page=100" 2>/dev/null | jq -cs 'add // []') || deps='[]'
  deployments='[]'
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    did=$(printf '%s' "$d" | jq -r .id)
    st=$(gh api "repos/$repo/deployments/$did/statuses?per_page=1" 2>/dev/null | jq -r '.[0].state // "pending"')
    deployments=$(printf '%s' "$deployments" | jq -c --argjson d "$d" --arg st "$st" --arg env "$deploy_env" '. + [{id: ($d.id|tostring), environment: $env, started_at: $d.created_at, finished_at: $d.updated_at, status: (if $st=="success" then "success" elif $st=="pending" or $st=="in_progress" or $st=="queued" then "pending" else "failure" end), sha: $d.sha}]')
  done < <(printf '%s' "$deps" | jq -c --arg s "$since_ts" --arg u "$until_ts" '.[] | select(.created_at >= $s and .created_at <= $u)')
fi

issues=$(cli gh issue list --repo "$repo" --label "$incident_label" --state all --limit 200 --json number,createdAt,closedAt,labels 2>/dev/null) || issues='[]'
incidents=$(printf '%s' "$issues" | jq -c --arg s "$since_ts" --arg u "$until_ts" '[.[] | select(.createdAt <= $u and (.createdAt >= $s or (.closedAt // "9999") >= $s)) | {id: (.number|tostring), opened_at: .createdAt, closed_at: .closedAt, labels: [(.labels // [])[] | .name]}]')

reverts='[]'
while IFS=$'\x1f' read -r sha date body; do
  [ -n "$sha" ] || continue
  target=$(printf '%s' "$body" | grep -oE 'reverts commit [0-9a-f]{7,40}' | head -n1 | awk '{print $3}')
  reverts=$(printf '%s' "$reverts" | jq -c --arg sha "$sha" --arg d "$date" --arg t "${target:-}" '. + [{sha:$sha, committed_at:$d, reverts_sha:(if $t=="" then null else $t end)}]')
done < <(git log --since="$since" --until="${until}T23:59:59" --grep='^Revert' --format='%H%x1f%cI%x1f%b%x1e' 2>/dev/null | tr -d '\n' | tr '\x1e' '\n')

mkdir -p "$(dirname "$out")" 2>/dev/null || true
jq -cn --arg repo "$repo" --arg s "$since" --arg u "$until" --arg now "$(sdlc_iso_now)" \
  --argjson prs "$prs" --argjson dep "$deployments" --argjson inc "$incidents" --argjson rev "$reverts" \
  '{platform:"github",repo:$repo,since:$s,until:$u,exported_at:$now,prs:$prs,deployments:$dep,incidents:$inc,reverts:$rev}' >"$out"
out_json "$(jq -c --arg out "$out" '{prs:(.prs|length),deployments:(.deployments|length),incidents:(.incidents|length),reverts:(.reverts|length),out:$out,platform:"github"}' "$out")"
