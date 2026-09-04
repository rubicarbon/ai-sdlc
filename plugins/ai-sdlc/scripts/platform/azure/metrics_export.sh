#!/usr/bin/env bash
# metrics_export (Azure DevOps): completed PRs, deploy pipeline runs, incident work
# items and reverts -> the normalised JSON shared with the GitHub adapter.
#   metrics_export <since> <until> <out.json>      (dates: YYYY-MM-DD, UTC)
# PR size and first-commit time come from the local git history when the merge
# commits are present; otherwise they are null and a warning says for how many PRs.
# Every CLI call must succeed and return JSON; a failure ends the export with exit 1 and
# no output file (the file is assembled in a temp location and moved at the end). The
# file records where each series came from ("sources") and coverage caveats
# ("warnings"). Under --dry-run nothing is written.
set -u
export SDLC_PLATFORM=azure
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
since="${1:-}"; until="${2:-}"; out="${3:-}"
[[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && "$until" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [ -n "$out" ] \
  || usage_die "metrics_export <since YYYY-MM-DD> <until YYYY-MM-DD> <out.json>"
require_az; az_context
incident_label=$(read_config '.metrics.incidentLabel' 'incident')
deploy_env=$(read_config '.metrics.deployEnvironment' 'production')
deploy_pipeline_id=$(read_config '.azure.deployPipelineId' '')
deploy_pipeline_name=$(read_config '.azure.deployPipelineName' 'sdlc-deploy')
max_prs=$(read_config '.metrics.maxPrs' 200)
default_branch=$(read_config '.repo.defaultBranch' 'main')
since_ts="${since}T00:00:00Z"; until_ts="${until}T23:59:59Z"
warnings=()
# The PAT, when present, travels in the Authorization header; it never appears in a
# log line or an error message (cli_json labels carry the method and URI only).
auth=(--resource 499b84ac-1321-427f-aa17-267ca6975798)
if [ -n "${AZURE_DEVOPS_EXT_PAT:-}" ]; then
  b64=$(printf ':%s' "$AZURE_DEVOPS_EXT_PAT" | base64 | tr -d '\n')
  auth=(--skip-authorization-header --headers "Authorization=Basic $b64")
fi

raw_prs=$(cli_json "az repos pr list --repository $AZ_REPO --status completed" az repos pr list --repository "$AZ_REPO" \
  --status completed --target-branch "$default_branch" --top 500 "${AZ_ARGS[@]}" -o json) || exit $?
printf '%s' "$raw_prs" | jq -e 'type=="array"' >/dev/null 2>&1 || sdlc_die 1 "az repos pr list returned an unexpected shape"
prs='[]'; n=0; no_local=0
while IFS= read -r pr; do
  [ -n "$pr" ] || continue
  n=$((n+1)); [ "$n" -gt "$max_prs" ] && break
  pid=$(printf '%s' "$pr" | jq -r .pullRequestId)
  src=$(printf '%s' "$pr" | jq -r '.lastMergeSourceCommit.commitId // empty')
  tgt=$(printf '%s' "$pr" | jq -r '.lastMergeTargetCommit.commitId // empty')
  uri="$AZ_ORG/$AZ_PROJECT/_apis/git/repositories/$AZ_REPO/pullRequests/$pid/threads?api-version=7.1"
  threads=$(cli_json "az rest --method get --uri $uri" az rest --method get --uri "$uri" "${auth[@]}" -o json) || exit $?
  first_review=$(printf '%s' "$threads" \
    | jq -r '[.value[]? | select(.properties.CodeReviewVoteResult != null) | .publishedDate] | min // empty')
  adds=null; dels=null; files=null; first_commit=null
  if [ -n "$src" ] && [ -n "$tgt" ] && git cat-file -e "$src^{commit}" 2>/dev/null && git cat-file -e "$tgt^{commit}" 2>/dev/null; then
    stat=$(git diff --shortstat "$tgt" "$src" 2>/dev/null)
    files=$(printf '%s' "$stat" | grep -oE '[0-9]+ files? changed' | grep -oE '^[0-9]+' || echo 0)
    adds=$(printf '%s' "$stat" | grep -oE '[0-9]+ insertions?' | grep -oE '^[0-9]+' || echo 0)
    dels=$(printf '%s' "$stat" | grep -oE '[0-9]+ deletions?' | grep -oE '^[0-9]+' || echo 0)
    fc=$(git log --format=%cI --reverse "$tgt..$src" 2>/dev/null | head -n1); [ -n "$fc" ] && first_commit=$(jq -cn --arg v "$fc" '$v')
  else
    no_local=$((no_local+1))
  fi
  prs=$(printf '%s' "$prs" | jq -c --argjson pr "$pr" --arg fr "${first_review:-}" --argjson a "$adds" --argjson d "$dels" \
    --argjson f "$files" --argjson fc "$first_commit" '. + [{
    id: ($pr.pullRequestId|tostring), created_at: $pr.creationDate, merged_at: $pr.closedDate,
    first_review_at: (if $fr=="" then null else $fr end), additions: $a, deletions: $d, changed_files: $f, first_commit_at: $fc,
    author: ($pr.createdBy.uniqueName // $pr.createdBy.displayName // null), is_revert: (($pr.title // "") | startswith("Revert"))}]')
done < <(printf '%s' "$raw_prs" | jq -c --arg s "$since_ts" --arg u "$until_ts" '.[] | select((.closedDate // "") >= $s and (.closedDate // "") <= $u)')
total=$(printf '%s' "$prs" | jq 'length')
[ "$no_local" -gt 0 ] && warnings+=("$no_local of $total pull requests have no local merge commits; size and first_commit_at are null for them")

# Deployments: runs of azure.deployPipelineId, else of the pipeline named
# azure.deployPipelineName. Neither -> "not-configured" and an empty series.
deployments='[]'; dep_source=configured
if [ -z "$deploy_pipeline_id" ] && [ -n "$deploy_pipeline_name" ]; then
  pipes=$(cli_json "az pipelines list --name $deploy_pipeline_name" az pipelines list --name "$deploy_pipeline_name" \
    --repository "$AZ_REPO" --repository-type tfsgit "${AZ_ARGS[@]}" -o json) || exit $?
  deploy_pipeline_id=$(printf '%s' "$pipes" | jq -r '.[0].id // empty')
fi
if [ -n "$deploy_pipeline_id" ]; then
  runs=$(cli_json "az pipelines runs list --pipeline-ids $deploy_pipeline_id" az pipelines runs list \
    --pipeline-ids "$deploy_pipeline_id" --top 200 --query-order FinishTimeDesc "${AZ_ARGS[@]}" -o json) || exit $?
  deployments=$(printf '%s' "$runs" | jq -c --arg s "$since_ts" --arg u "$until_ts" --arg env "$deploy_env" '
    [.[] | select((.finishTime // .queueTime // "") >= $s and (.finishTime // .queueTime // "") <= $u) | {
      id: (.id|tostring), environment: $env, started_at: .queueTime, finished_at: .finishTime,
      status: (if .result=="succeeded" then "success" elif .result==null then "pending" else "failure" end),
      sha: (.sourceVersion // null)}]') || sdlc_die 1 "az pipelines runs list returned an unexpected shape"
else
  dep_source=not-configured
  warnings+=("no deploy pipeline configured (set azure.deployPipelineId, or register a pipeline named '${deploy_pipeline_name:-sdlc-deploy}'): deployments are empty")
fi

wiql="SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.Tags] CONTAINS '$incident_label' AND [System.CreatedDate] <= '$until' ORDER BY [System.CreatedDate]"
raw_inc=$(cli_json "az boards query --wiql <incidents tagged $incident_label>" az boards query --wiql "$wiql" "${AZ_ARGS[@]}" -o json) || exit $?
incidents=$(printf '%s' "$raw_inc" | jq -c --arg s "$since_ts" '
  [.[] | .fields as $f | {id: ((.id // $f["System.Id"])|tostring), opened_at: $f["System.CreatedDate"],
    closed_at: ($f["Microsoft.VSTS.Common.ClosedDate"] // null),
    labels: (($f["System.Tags"] // "") | split(";") | map(ltrimstr(" ")|rtrimstr(" ")) | map(select(length>0)))}
   | select(.opened_at >= $s or (.closed_at // "9999") >= $s)]') || sdlc_die 1 "az boards query returned an unexpected shape"

sdlc_reverts_scan "$since" "$until"
[ -n "$REVERTS_WARNING" ] && warnings+=("$REVERTS_WARNING")

doc=$(jq -cn --arg repo "$AZ_PROJECT/$AZ_REPO" --arg s "$since" --arg u "$until" --arg now "$(sdlc_iso_now)" \
  --arg dep_src "$dep_source" --arg rev_src "$REVERTS_SOURCE" \
  --argjson prs "$prs" --argjson dep "$deployments" --argjson inc "$incidents" --argjson rev "$REVERTS_JSON" \
  --argjson warn "$(json_list "${warnings[@]+"${warnings[@]}"}")" \
  '{platform:"azure", repo:$repo, since:$s, until:$u, exported_at:$now,
    sources:{prs:"configured", deployments:$dep_src, incidents:"configured", reverts:$rev_src},
    warnings:$warn, prs:$prs, deployments:$dep, incidents:$inc, reverts:$rev}')
if [ "${SDLC_DRY_RUN:-0}" != "1" ]; then
  tmp=$(sdlc_tmpfile .json); printf '%s\n' "$doc" >"$tmp"
  case "$out" in */*) mkdir -p "${out%/*}" ;; esac
  mv "$tmp" "$out" || { rm -f "$tmp"; sdlc_die 1 "cannot write $out"; }
fi
out_json "$(printf '%s' "$doc" | jq -c --arg out "$out" '{prs:(.prs|length), deployments:(.deployments|length),
  incidents:(.incidents|length), reverts:(.reverts|length), out:$out, warnings:.warnings, platform:"azure"}')"
