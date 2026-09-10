#!/usr/bin/env bash
# branch_protect_apply (Azure DevOps): make the branch policies described in
# templates/azure/branch-policies.json true for <branch>. For every desired policy the
# adapter looks for an existing policy of the same type whose scope is exactly
# refs/heads/<branch> in this repository, then compares the settings ai-sdlc manages
# (never display names): missing -> create ("applied"), different -> update in place
# ("updated"), equal -> "unchanged". Policies of other types, other branches or other
# repositories are never touched. Azure Repos has no CODEOWNERS; the human gate is the
# "Required reviewers" policy fed from azure.requiredReviewers in the config.
# The build policy follows review_pipeline_name (_common.sh): azure.pipelineName when set,
# sdlc-pr-review for review.runner ci, none for review.runner local. With runner local every
# existing build policy on the branch whose display name is sdlc-pr-review (the retired review
# pipeline) is deleted and listed under "removed", independent of a custom pipeline; a custom
# build policy is never removed. A successful run marks the review-runner migration remote
# side done in <artifacts>/migrations.json.
set -u
export SDLC_PLATFORM=azure
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
branch="${1:-}"; [ -n "$branch" ] || usage_die "branch_protect_apply <branch>"
require_az; az_context

approvals=$(read_config '.review.requiredApprovals' 1)
reviewers_json=$(config_array '.azure.requiredReviewers')
pipeline_name=$(review_pipeline_name); runner=$(review_runner)
tmpl=branch-policies.json; pipeline_var=(--var "AZURE_PIPELINE_NAME=$pipeline_name")
[ -n "$pipeline_name" ] || { tmpl=branch-policies-local.json; pipeline_var=(); }
plan=$(bash "$SDLC_PLUGIN_ROOT/scripts/init/render.sh" "$SDLC_PLUGIN_ROOT/templates/azure/$tmpl" \
  --var "REPO_DEFAULT_BRANCH=$branch" --var "REVIEW_REQUIRED_APPROVALS=$approvals" \
  --var "AZURE_REQUIRED_REVIEWERS_JSON=$reviewers_json" "${pipeline_var[@]+"${pipeline_var[@]}"}" \
  ${SDLC_CONFIG:+--config "$SDLC_CONFIG"}) || sdlc_die 1 "could not render $tmpl"

repo_json=$(cli_json "az repos show --repository $AZ_REPO" az repos show --repository "$AZ_REPO" "${AZ_ARGS[@]}" -o json) || exit $?
repo_id=$(printf '%s' "$repo_json" | jq -r '.id // empty')
[ -n "$repo_id" ] || sdlc_die 1 "az repos show returned no repository id: ${repo_json:0:120}"
existing=$(cli_json "az repos policy list --branch $branch" az repos policy list --branch "$branch" \
  --repository-id "$repo_id" "${AZ_ARGS[@]}" -o json) || exit $?
printf '%s' "$existing" | jq -e 'type=="array"' >/dev/null 2>&1 \
  || sdlc_die 1 "az repos policy list returned an unexpected shape: ${existing:0:120}"

# Well-known policy type ids (the display name is accepted as a fallback).
type_of() {  # type_of <kind> -> sets TYPE_ID and TYPE_NAME, returns 1 for unknown kinds
  case "$1" in
    approver-count)    TYPE_ID=fa4e907d-c16b-4a4c-9dfa-4906e5d171dd; TYPE_NAME="Minimum number of reviewers" ;;
    required-reviewer) TYPE_ID=fd2167ab-b0be-447a-8ec8-39368250530e; TYPE_NAME="Required reviewers" ;;
    build)             TYPE_ID=0609b952-1397-4640-95ec-e00a01b2c241; TYPE_NAME="Build" ;;
    work-item-linking) TYPE_ID=40e92b44-2fe1-4dd6-b3d8-74a9c21d0c6e; TYPE_NAME="Work item linking" ;;
    comment-required)  TYPE_ID=c6a1889d-b943-4856-b76f-9e46bb6b0df2; TYPE_NAME="Comment requirements" ;;
    *) return 1 ;;
  esac
}

# find_existing <type-id> <type-name> -> the first existing policy of that type scoped
# exactly to refs/heads/<branch> in this repository (repositoryId equal or null), or "".
find_existing() {
  printf '%s' "$existing" | jq -c --arg tid "$1" --arg dn "$2" --arg ref "refs/heads/$branch" --arg repo "$repo_id" '
    [.[] | select(((.type.id // "") | ascii_downcase) == ($tid | ascii_downcase) or (.type.displayName // "") == $dn)
         | select(any((.settings.scope // [])[];
             (.refName // "") == $ref
             and (((.matchKind // "exact") | tostring | ascii_downcase) == "exact")
             and ((.repositoryId // null) == null
                  or ((.repositoryId | tostring | ascii_downcase) == ($repo | ascii_downcase)))))]
    | first // empty'
}

# The managed view of a policy: the same projection is applied to the desired object and
# to the existing one, so types line up before comparison.
managed='def b: if type=="string" then (ascii_downcase=="true") elif . == null then false else . end;
  def n: if type=="string" then (tonumber? // 0) elif . == null then 0 else . end;
  def managed($k):
    {isEnabled: (.isEnabled | b), isBlocking: (.isBlocking | b)}
    + (if $k == "approver-count" then
         {minimumApproverCount: (.settings.minimumApproverCount | n),
          creatorVoteCounts: (.settings.creatorVoteCounts | b),
          allowDownvotes: (.settings.allowDownvotes | b),
          resetOnSourcePush: (.settings.resetOnSourcePush | b)}
       elif $k == "required-reviewer" then
         {requiredReviewerIds: ((.settings.requiredReviewerIds // []) | map(tostring | ascii_downcase) | unique),
          message: (.settings.message // "")}
       elif $k == "build" then
         {buildDefinitionId: ((.settings.buildDefinitionId // "") | tostring),
          displayName: (.settings.displayName // ""),
          queueOnSourceUpdateOnly: (.settings.queueOnSourceUpdateOnly | b),
          manualQueueOnly: (.settings.manualQueueOnly | b),
          validDuration: (.settings.validDuration | n)}
       else {} end);'
managed_eq() {  # managed_eq <kind> <desired-json> <existing-json>
  jq -en --arg k "$1" --argjson w "$2" --argjson c "$3" "$managed"' ($w | managed($k)) == ($c | managed($k))' >/dev/null
}

applied=(); updated=(); unchanged=(); skipped=(); removed=()
common=(--blocking true --enabled true --branch "$branch" --repository-id "$repo_id" "${AZ_ARGS[@]}" -o json)

# review.runner local: the review pipeline's build policy is obsolete. Every build policy on
# this branch (and repository) named sdlc-pr-review goes; any other build policy stays.
if [ "$runner" = local ]; then
  while IFS= read -r obs_id; do
    [ -n "$obs_id" ] || continue
    cli az repos policy delete --id "$obs_id" --yes "${AZ_ARGS[@]}" >/dev/null \
      || sdlc_die 1 "az repos policy delete --id $obs_id failed"
    removed+=("build: sdlc-pr-review (policy $obs_id)")
  done < <(printf '%s' "$existing" | jq -r --arg ref "refs/heads/$branch" --arg repo "$repo_id" '
    .[] | select(((.type.id // "") | ascii_downcase) == "0609b952-1397-4640-95ec-e00a01b2c241" or (.type.displayName // "") == "Build")
        | select((.settings.displayName // "") == "sdlc-pr-review")
        | select(any((.settings.scope // [])[]; (.refName // "") == $ref
              and ((.repositoryId // null) == null or ((.repositoryId | tostring | ascii_downcase) == ($repo | ascii_downcase)))))
        | .id')
fi
while IFS= read -r pol; do
  kind=$(printf '%s' "$pol" | jq -r .kind)
  type_of "$kind" || { skipped+=("$kind: unknown policy kind in template"); continue; }
  args=()
  case "$kind" in
    approver-count)
      desired=$(printf '%s' "$pol" | jq -c '{isEnabled:true, isBlocking:true, settings:{
        minimumApproverCount:(.settings.minimumApproverCount // 1), creatorVoteCounts:(.settings.creatorVoteCounts // false),
        allowDownvotes:(.settings.allowDownvotes // false), resetOnSourcePush:(.settings.resetOnSourcePush // true)}}')
      args=(--minimum-approver-count "$(printf '%s' "$desired" | jq -r .settings.minimumApproverCount)"
            --creator-vote-counts "$(printf '%s' "$desired" | jq -r .settings.creatorVoteCounts)"
            --allow-downvotes "$(printf '%s' "$desired" | jq -r .settings.allowDownvotes)"
            --reset-on-source-push "$(printf '%s' "$desired" | jq -r .settings.resetOnSourcePush)") ;;
    required-reviewer)
      ids=$(printf '%s' "$pol" | jq -r '(.settings.requiredReviewerIds // []) | map(tostring) | join(";")')
      if [ -z "$ids" ]; then skipped+=("required-reviewer: set azure.requiredReviewers in sdlc.config.json"); continue; fi
      desired=$(printf '%s' "$pol" | jq -c '{isEnabled:true, isBlocking:true, settings:{
        requiredReviewerIds:(.settings.requiredReviewerIds // []), message:(.settings.message // "")}}')
      args=(--required-reviewer-ids "$ids" --message "$(printf '%s' "$desired" | jq -r .settings.message)") ;;
    work-item-linking|comment-required)
      desired='{"isEnabled":true,"isBlocking":true,"settings":{}}' ;;
    build)
      pname=$(printf '%s' "$pol" | jq -r .settings.pipelineName)
      pipes=$(cli_json "az pipelines list --name $pname" az pipelines list --name "$pname" --repository "$AZ_REPO" \
        --repository-type tfsgit "${AZ_ARGS[@]}" -o json) || exit $?
      def_id=$(printf '%s' "$pipes" | jq -r '.[0].id // empty')
      if [ -z "$def_id" ]; then skipped+=("build: pipeline '$pname' is not registered yet (run ci_workflow_install first)"); continue; fi
      desired=$(printf '%s' "$pol" | jq -c --arg id "$def_id" --arg dn "$pname" '{isEnabled:true, isBlocking:true, settings:{
        buildDefinitionId:$id, displayName:$dn, queueOnSourceUpdateOnly:(.settings.queueOnSourceUpdateOnly // true),
        manualQueueOnly:(.settings.manualQueueOnly // false), validDuration:(.settings.validDuration // 720)}}')
      args=(--build-definition-id "$def_id" --display-name "$pname"
            --manual-queue-only "$(printf '%s' "$desired" | jq -r .settings.manualQueueOnly)"
            --queue-on-source-update-only "$(printf '%s' "$desired" | jq -r .settings.queueOnSourceUpdateOnly)"
            --valid-duration "$(printf '%s' "$desired" | jq -r .settings.validDuration)") ;;
  esac
  ex=$(find_existing "$TYPE_ID" "$TYPE_NAME")
  if [ -z "$ex" ]; then
    cli az repos policy "$kind" create "${args[@]+"${args[@]}"}" "${common[@]}" >/dev/null \
      || sdlc_die 1 "az repos policy $kind create failed"
    applied+=("$kind")
  elif managed_eq "$kind" "$desired" "$ex"; then
    unchanged+=("$kind")
  else
    ex_id=$(printf '%s' "$ex" | jq -r .id)
    cli az repos policy "$kind" update --id "$ex_id" "${args[@]+"${args[@]}"}" "${common[@]}" >/dev/null \
      || sdlc_die 1 "az repos policy $kind update --id $ex_id failed"
    updated+=("$kind")
  fi
done < <(printf '%s' "$plan" | jq -c '.policies[]')

migration_remote_done
out_json "$(jq -cn --arg b "$branch" \
  --argjson a "$(json_list "${applied[@]+"${applied[@]}"}")" --argjson up "$(json_list "${updated[@]+"${updated[@]}"}")" \
  --argjson u "$(json_list "${unchanged[@]+"${unchanged[@]}"}")" --argjson s "$(json_list "${skipped[@]+"${skipped[@]}"}")" \
  --argjson r "$(json_list "${removed[@]+"${removed[@]}"}")" \
  '{branch:$b, applied:$a, updated:$up, unchanged:$u, skipped:$s, removed:$r, platform:"azure"}')"
