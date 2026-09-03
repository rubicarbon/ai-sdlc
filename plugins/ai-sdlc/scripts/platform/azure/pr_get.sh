#!/usr/bin/env bash
# pr_get (Azure DevOps): normalised pull request JSON. Size fields are null:
# the CLI does not expose them (metrics_export computes them from git).
set -u
export SDLC_PLATFORM=azure
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
id="${1:-}"; [[ "$id" =~ ^[0-9]+$ ]] || usage_die "pr_get <id>"
require_az; az_context
raw=$(cli az repos pr show --id "$id" "${AZ_ARGS[@]}" -o json) || sdlc_die 1 "az repos pr show $id failed"
out_json "$(printf '%s' "$raw" | jq -c --arg fallback "$AZ_ORG/$AZ_PROJECT/_git/$AZ_REPO" '
  (.reviewers // []) as $r
  | {
    id: (.pullRequestId|tostring), title,
    state: (if .status=="completed" then "merged" elif .status=="abandoned" then "closed" else "open" end),
    base: ((.targetRefName // "") | ltrimstr("refs/heads/")), head: ((.sourceRefName // "") | ltrimstr("refs/heads/")),
    url: ((.repository.webUrl // $fallback) + "/pullrequest/" + (.pullRequestId|tostring)),
    created_at: .creationDate, merged_at: (if .status=="completed" then .closedDate else null end), closed_at: (.closedDate // null),
    additions: null, deletions: null, changed_files: null,
    review_decision: (if any($r[]; (.vote // 0) < 0) then "changes_requested" elif any($r[]; (.vote // 0) > 0) then "approved" else "pending" end),
    author: (.createdBy.uniqueName // .createdBy.displayName // null), platform: "azure"}')"
