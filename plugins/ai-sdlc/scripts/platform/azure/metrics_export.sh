#!/usr/bin/env bash
# metrics_export (Azure DevOps): completed PRs, deploy pipeline runs, incident work
# items and reverts -> the normalised JSON shared with the GitHub adapter.
#   metrics_export <since> <until> <out.json>      (dates: YYYY-MM-DD, UTC)
# PR size and first-commit time come from the local git history when the merge
# commits are present; otherwise they are null and reported as such.
set -u
export SDLC_PLATFORM=azure
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
since="${1:-}"; until="${2:-}"; out="${3:-}"
[[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && "$until" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [ -n "$out" ] || usage_die "metrics_export <since YYYY-MM-DD> <until YYYY-MM-DD> <out.json>"
require_az; az_context
incident_label=$(read_config '.metrics.incidentLabel' 'incident')
deploy_env=$(read_config '.metrics.deployEnvironment' 'production')
deploy_pipeline_id=$(read_config '.azure.deployPipelineId' '')
deploy_pipeline_name=$(read_config '.azure.deployPipelineName' 'sdlc-deploy')
max_prs=$(read_config '.metrics.maxPrs' 200)
default_branch=$(read_config '.repo.defaultBranch' 'main')
since_ts="${since}T00:00:00Z"; until_ts="${until}T23:59:59Z"
auth=(--resource 499b84ac-1321-427f-aa17-267ca6975798)
if [ -n "${AZURE_DEVOPS_EXT_PAT:-}" ]; then b64=$(printf ':%s' "$AZURE_DEVOPS_EXT_PAT" | base64 | tr -d '\n'); auth=(--skip-authorization-header --headers "Authorization=Basic $b64"); fi

raw_prs=$(cli az repos pr list --repository "$AZ_REPO" --status completed --target-branch "$default_branch" --top 500 "${AZ_ARGS[@]}" -o json 2>/dev/null) || raw_prs='[]'
prs='[]'; n=0
while IFS= read -r pr; do
  [ -n "$pr" ] || continue
  n=$((n+1)); [ "$n" -gt "$max_prs" ] && break
  pid=$(printf '%s' "$pr" | jq -r .pullRequestId)
  src=$(printf '%s' "$pr" | jq -r '.lastMergeSourceCommit.commitId // empty'); tgt=$(printf '%s' "$pr" | jq -r '.lastMergeTargetCommit.commitId // empty')
  first_review=$(az rest --method get --uri "$AZ_ORG/$AZ_PROJECT/_apis/git/repositories/$AZ_REPO/pullRequests/$pid/threads?api-version=7.1" "${auth[@]}" -o json 2>/dev/null \
    | jq -r '[.value[]? | select(.properties.CodeReviewVoteResult != null) | .publishedDate] | min // empty')
  adds=null; dels=null; files=null; first_commit=null
  if [ -n "$src" ] && [ -n "$tgt" ] && git cat-file -e "$src^{commit}" 2>/dev/null && git cat-file -e "$tgt^{commit}" 2>/dev/null; then
    stat=$(git diff --shortstat "$tgt" "$src" 2>/dev/null)
    files=$(printf '%s' "$stat" | grep -oE '[0-9]+ files? changed' | grep -oE '^[0-9]+' || echo 0)
    adds=$(printf '%s' "$stat" | grep -oE '[0-9]+ insertions?' | grep -oE '^[0-9]+' || echo 0)
    dels=$(printf '%s' "$stat" | grep -oE '[0-9]+ deletions?' | grep -oE '^[0-9]+' || echo 0)
    fc=$(git log --format=%cI --reverse "$tgt..$src" 2>/dev/null | head -n1); [ -n "$fc" ] && first_commit=$(jq -cn --arg v "$fc" '$v')
  fi
  prs=$(printf '%s' "$prs" | jq -c --argjson pr "$pr" --arg fr "${first_review:-}" --argjson a "$adds" --argjson d "$dels" --argjson f "$files" --argjson fc "$first_commit" '. + [{
    id: ($pr.pullRequestId|tostring), created_at: $pr.creationDate, merged_at: $pr.closedDate,
    first_review_at: (if $fr=="" then null else $fr end), additions: $a, deletions: $d, changed_files: $f, first_commit_at: $fc,
    author: ($pr.createdBy.uniqueName // $pr.createdBy.displayName // null), is_revert: (($pr.title // "") | startswith("Revert"))}]')
done < <(printf '%s' "$raw_prs" | jq -c --arg s "$since_ts" --arg u "$until_ts" '.[] | select((.closedDate // "") >= $s and (.closedDate // "") <= $u)')

deployments='[]'
if [ -z "$deploy_pipeline_id" ] && [ -n "$deploy_pipeline_name" ]; then
  deploy_pipeline_id=$(az pipelines list --name "$deploy_pipeline_name" --repository "$AZ_REPO" --repository-type tfsgit "${AZ_ARGS[@]}" -o json 2>/dev/null | jq -r '.[0].id // empty')
fi
if [ -n "$deploy_pipeline_id" ]; then
  runs=$(cli az pipelines runs list --pipeline-ids "$deploy_pipeline_id" --top 200 --query-order FinishTimeDesc "${AZ_ARGS[@]}" -o json 2>/dev/null) || runs='[]'
  deployments=$(printf '%s' "$runs" | jq -c --arg s "$since_ts" --arg u "$until_ts" --arg env "$deploy_env" '[.[] | select((.finishTime // .queueTime // "") >= $s and (.finishTime // .queueTime // "") <= $u) | {
    id: (.id|tostring), environment: $env, started_at: .queueTime, finished_at: .finishTime,
    status: (if .result=="succeeded" then "success" elif .result==null then "pending" else "failure" end), sha: (.sourceVersion // null)}]')
else
  sdlc_log "no deploy pipeline configured (azure.deployPipelineName or azure.deployPipelineId): deployments will be empty"
fi

wiql="SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.Tags] CONTAINS '$incident_label' AND [System.CreatedDate] <= '$until' ORDER BY [System.CreatedDate]"
raw_inc=$(cli az boards query --wiql "$wiql" "${AZ_ARGS[@]}" -o json 2>/dev/null) || raw_inc='[]'
incidents=$(printf '%s' "$raw_inc" | jq -c --arg s "$since_ts" '[.[] | .fields as $f | {id: ((.id // $f["System.Id"])|tostring), opened_at: $f["System.CreatedDate"], closed_at: ($f["Microsoft.VSTS.Common.ClosedDate"] // null), labels: (($f["System.Tags"] // "") | split(";") | map(ltrimstr(" ")|rtrimstr(" ")) | map(select(length>0)))} | select(.opened_at >= $s or (.closed_at // "9999") >= $s)]')

reverts='[]'
while IFS=$'\x1f' read -r sha date body; do
  [ -n "$sha" ] || continue
  target=$(printf '%s' "$body" | grep -oE 'reverts commit [0-9a-f]{7,40}' | head -n1 | awk '{print $3}')
  reverts=$(printf '%s' "$reverts" | jq -c --arg sha "$sha" --arg d "$date" --arg t "${target:-}" '. + [{sha:$sha, committed_at:$d, reverts_sha:(if $t=="" then null else $t end)}]')
done < <(git log --since="$since" --until="${until}T23:59:59" --grep='^Revert' --format='%H%x1f%cI%x1f%b%x1e' 2>/dev/null | tr -d '\n' | tr '\x1e' '\n')

mkdir -p "$(dirname "$out")" 2>/dev/null || true
jq -cn --arg repo "$AZ_PROJECT/$AZ_REPO" --arg s "$since" --arg u "$until" --arg now "$(sdlc_iso_now)" \
  --argjson prs "$prs" --argjson dep "$deployments" --argjson inc "$incidents" --argjson rev "$reverts" \
  '{platform:"azure",repo:$repo,since:$s,until:$u,exported_at:$now,prs:$prs,deployments:$dep,incidents:$inc,reverts:$rev}' >"$out"
out_json "$(jq -c --arg out "$out" '{prs:(.prs|length),deployments:(.deployments|length),incidents:(.incidents|length),reverts:(.reverts|length),out:$out,platform:"azure"}' "$out")"
