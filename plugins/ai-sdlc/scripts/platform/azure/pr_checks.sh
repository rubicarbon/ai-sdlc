#!/usr/bin/env bash
# pr_checks (Azure DevOps): branch policy evaluations of a PR as normalised checks.
# Exit 0 pass, 1 fail, 8 pending. The verdict rules live in _common.sh
# (pr_checks_result) and are shared with GitHub: the function never passes with zero
# evaluations, and the build policy for the required pipeline (review_pipeline_name in
# _common.sh: azure.pipelineName when set, else sdlc-pr-review for review.runner ci, else
# none) must be present and approved (an evaluation named "Build (<pipeline>)" satisfies
# the required name). With review.runner local and no custom pipeline `required` is [].
set -u
export SDLC_PLATFORM=azure
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
id="${1:-}"; [[ "$id" =~ ^[0-9]+$ ]] || usage_die "pr_checks <id>"
require_az; az_context
pipeline_name=$(review_pipeline_name)
required=$(jq -cn --arg n "$pipeline_name" '[$n | select(length>0)]')

raw=$(cli_json "az repos pr policy list --id $id" az repos pr policy list --id "$id" "${AZ_ARGS[@]}" -o json) || exit $?
printf '%s' "$raw" | jq -e 'type=="array"' >/dev/null 2>&1 \
  || sdlc_die 1 "az repos pr policy list --id $id returned an unexpected shape: ${raw:0:120}"

checks=$(printf '%s' "$raw" | jq -c --arg build "$AZ_ORG/$AZ_PROJECT/_build/results?buildId=" '
  def norm: ascii_downcase | if .=="approved" then "pass" elif IN("rejected","broken") then "fail"
    elif .=="notapplicable" then "skipped" else "pending" end;
  [.[] | {
    name: ((.configuration.type.displayName // "policy")
      + (if .configuration.settings.displayName then " (" + .configuration.settings.displayName + ")" else "" end)),
    status: ((.status // "queued") | norm),
    url: (if .context.buildId then ($build + (.context.buildId|tostring)) else null end)}]')
result=$(pr_checks_result "$id" azure "$checks" "$required")
out_json "$result"
pr_checks_exit "$result"
