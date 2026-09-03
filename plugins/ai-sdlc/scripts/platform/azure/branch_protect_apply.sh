#!/usr/bin/env bash
# branch_protect_apply (Azure DevOps): create the branch policies described in
# templates/azure/branch-policies.json. Idempotent: a policy type already scoped
# to the branch is left alone. Azure Repos has no CODEOWNERS; the human gate is
# the "Required reviewers" policy fed from azure.requiredReviewers in the config.
set -u
export SDLC_PLATFORM=azure
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
branch="${1:-}"; [ -n "$branch" ] || usage_die "branch_protect_apply <branch>"
require_az; az_context

approvals=$(read_config '.review.requiredApprovals' 1)
reviewers_json=$(read_config '.azure.requiredReviewers' '[]'); printf '%s' "$reviewers_json" | jq -e 'type=="array"' >/dev/null 2>&1 || reviewers_json='[]'
pipeline_name=$(read_config '.azure.pipelineName' 'sdlc-pr-review')
plan=$(bash "$SDLC_PLUGIN_ROOT/scripts/init/render.sh" "$SDLC_PLUGIN_ROOT/templates/azure/branch-policies.json" \
  --var "REPO_DEFAULT_BRANCH=$branch" --var "REVIEW_REQUIRED_APPROVALS=$approvals" --var "AZURE_REQUIRED_REVIEWERS_JSON=$reviewers_json" --var "AZURE_PIPELINE_NAME=$pipeline_name" ${SDLC_CONFIG:+--config "$SDLC_CONFIG"}) || sdlc_die 1 "could not render branch-policies.json"

repo_id=$(az_repo_json | jq -r '.id') || sdlc_die 1 "az repos show failed"
existing=$(az repos policy list --branch "$branch" --repository-id "$repo_id" "${AZ_ARGS[@]}" -o json 2>/dev/null || echo '[]')
existing_names=$(printf '%s' "$existing" | jq -c --arg b "refs/heads/$branch" '[.[] | select(any((.settings.scope // [])[]; (.refName // "") == $b or (.refName // "") == "")) | .type.displayName]')

applied=(); unchanged=(); skipped=()
common=(--blocking true --enabled true --branch "$branch" --repository-id "$repo_id" "${AZ_ARGS[@]}" -o json)
while IFS= read -r pol; do
  kind=$(printf '%s' "$pol" | jq -r .kind); dn=$(printf '%s' "$pol" | jq -r .displayName)
  if printf '%s' "$existing_names" | jq -e --arg dn "$dn" 'index($dn) != null' >/dev/null; then unchanged+=("$kind"); continue; fi
  case "$kind" in
    approver-count)
      cli az repos policy approver-count create --minimum-approver-count "$(printf '%s' "$pol" | jq -r .settings.minimumApproverCount)" \
        --creator-vote-counts false --allow-downvotes false --reset-on-source-push true "${common[@]}" >/dev/null || sdlc_die 1 "approver-count policy failed" ;;
    required-reviewer)
      ids=$(printf '%s' "$pol" | jq -r '.settings.requiredReviewerIds | join(";")')
      if [ -z "$ids" ]; then skipped+=("required-reviewer: set azure.requiredReviewers in sdlc.config.json"); continue; fi
      cli az repos policy required-reviewer create --required-reviewer-ids "$ids" --message "$(printf '%s' "$pol" | jq -r .settings.message)" "${common[@]}" >/dev/null || sdlc_die 1 "required-reviewer policy failed" ;;
    work-item-linking)
      cli az repos policy work-item-linking create "${common[@]}" >/dev/null || sdlc_die 1 "work-item-linking policy failed" ;;
    comment-required)
      cli az repos policy comment-required create "${common[@]}" >/dev/null || sdlc_die 1 "comment-required policy failed" ;;
    build)
      pname=$(printf '%s' "$pol" | jq -r .settings.pipelineName)
      def_id=$(az pipelines list --name "$pname" --repository "$AZ_REPO" --repository-type tfsgit "${AZ_ARGS[@]}" -o json 2>/dev/null | jq -r '.[0].id // empty')
      if [ -z "$def_id" ]; then skipped+=("build: pipeline '$pname' is not registered yet (run ci_workflow_install first)"); continue; fi
      cli az repos policy build create --build-definition-id "$def_id" --display-name "$pname" --manual-queue-only false --queue-on-source-update-only true --valid-duration 720 "${common[@]}" >/dev/null || sdlc_die 1 "build policy failed" ;;
    *) skipped+=("$kind: unknown policy kind in template") ; continue ;;
  esac
  applied+=("$kind")
done < <(printf '%s' "$plan" | jq -c '.policies[]')

j() { printf '%s\n' "$@" | jq -R . | jq -cs 'map(select(length>0))'; }
out_json "$(jq -cn --arg b "$branch" --argjson a "$(j "${applied[@]+"${applied[@]}"}")" --argjson u "$(j "${unchanged[@]+"${unchanged[@]}"}")" --argjson s "$(j "${skipped[@]+"${skipped[@]}"}")" '{branch:$b,applied:$a,unchanged:$u,skipped:$s,platform:"azure"}')"
