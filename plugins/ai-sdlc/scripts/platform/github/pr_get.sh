#!/usr/bin/env bash
# pr_get (GitHub): normalised pull request JSON.
set -u
export SDLC_PLATFORM=github
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
id="${1:-}"; [[ "$id" =~ ^[0-9]+$ ]] || usage_die "pr_get <id>"
require_gh
repo=$(gh_repo)
raw=$(cli gh pr view "$id" --repo "$repo" --json number,title,state,baseRefName,headRefName,url,createdAt,mergedAt,closedAt,additions,deletions,changedFiles,reviewDecision,author) || sdlc_die 1 "gh pr view $id failed"
out_json "$(printf '%s' "$raw" | jq -c '{
  id: (.number|tostring), title,
  state: (if .state=="MERGED" then "merged" elif .state=="CLOSED" then "closed" else "open" end),
  base: .baseRefName, head: .headRefName, url, created_at: .createdAt, merged_at: .mergedAt, closed_at: .closedAt,
  additions, deletions, changed_files: .changedFiles,
  review_decision: (if .reviewDecision=="APPROVED" then "approved" elif .reviewDecision=="CHANGES_REQUESTED" then "changes_requested" else "pending" end),
  author: (.author.login // null), platform: "github"}')"
