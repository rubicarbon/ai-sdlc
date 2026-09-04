#!/usr/bin/env bash
# pr_get (Azure DevOps): normalised pull request JSON. Size fields are null:
# the CLI does not expose them (metrics_export computes them from git).
#
# review_decision follows Azure votes (10 approved, 5 approved with suggestions, 0 no
# vote, -5 waiting for author, -10 rejected):
#   changes_requested  any reviewer voted below 0;
#   approved           all of: approvals (vote >= 5, the PR author and group/container
#                      entries excluded) >= review.requiredApprovals (default 1, never
#                      below 1); every
#                      name in azure.requiredReviewers (matched case-insensitively against
#                      uniqueName, displayName or id) voted >= 5; every reviewer flagged
#                      isRequired voted >= 5. The author's own vote never counts;
#   pending            otherwise.
set -u
export SDLC_PLATFORM=azure
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
id="${1:-}"; [[ "$id" =~ ^[0-9]+$ ]] || usage_die "pr_get <id>"
require_az; az_context
approvals=$(read_config '.review.requiredApprovals' 1)
[[ "$approvals" =~ ^[0-9]+$ ]] || approvals=1
required=$(config_array '.azure.requiredReviewers')
raw=$(cli_json "az repos pr show --id $id" az repos pr show --id "$id" "${AZ_ARGS[@]}" -o json) || exit $?
out_json "$(printf '%s' "$raw" | jq -c --arg fallback "$AZ_ORG/$AZ_PROJECT/_git/$AZ_REPO" \
  --argjson need "$approvals" --argjson required "$required" '
  def lc: (. // "") | tostring | ascii_downcase;
  (.reviewers // []) as $r
  | (.createdBy // {}) as $a
  | [$r[] | select(
        (((.uniqueName|lc) != "" and (.uniqueName|lc) == ($a.uniqueName|lc))
         or ((.id|lc) != "" and (.id|lc) == ($a.id|lc))) | not)] as $others
  | ([$others[] | select(((.isContainer // false) | not) and (.vote // 0) >= 5)] | length) as $count
  | ($required | map(lc)) as $names
  | (all($names[]; . as $n | any($others[]; (.vote // 0) >= 5
        and ((.uniqueName|lc) == $n or (.displayName|lc) == $n or (.id|lc) == $n)))) as $named_ok
  | (all($others[] | select(.isRequired == true); (.vote // 0) >= 5)) as $flagged_ok
  | {
    id: (.pullRequestId|tostring), title,
    state: (if .status=="completed" then "merged" elif .status=="abandoned" then "closed" else "open" end),
    base: ((.targetRefName // "") | ltrimstr("refs/heads/")), head: ((.sourceRefName // "") | ltrimstr("refs/heads/")),
    url: ((.repository.webUrl // $fallback) + "/pullrequest/" + (.pullRequestId|tostring)),
    created_at: .creationDate, merged_at: (if .status=="completed" then .closedDate else null end),
    closed_at: (.closedDate // null),
    additions: null, deletions: null, changed_files: null,
    review_decision: (if any($r[]; (.vote // 0) < 0) then "changes_requested"
      elif $count >= ([$need, 1] | max) and $named_ok and $flagged_ok then "approved" else "pending" end),
    author: (.createdBy.uniqueName // .createdBy.displayName // null), platform: "azure"}')"
