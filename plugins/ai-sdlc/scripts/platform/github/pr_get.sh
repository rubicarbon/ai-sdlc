#!/usr/bin/env bash
# pr_get (GitHub): normalised pull request JSON.
set -u
export SDLC_PLATFORM=github
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
id="${1:-}"; [[ "$id" =~ ^[0-9]+$ ]] || usage_die "pr_get <id>"
require_gh
repo=$(gh_repo)
raw=$(cli gh pr view "$id" --repo "$repo" --json number,title,body,state,baseRefName,headRefName,baseRefOid,headRefOid,headRepository,headRepositoryOwner,isCrossRepository,url,createdAt,mergedAt,closedAt,additions,deletions,changedFiles,reviewDecision,author) || sdlc_die 1 "gh pr view $id failed"
# head_repo / head_repo_url name the repository the head branch lives in (a fork on a
# cross-repository PR), so a reviewer can fetch exactly the commit head_sha.
out_json "$(printf '%s' "$raw" | jq -c --arg repo "$repo" '
  (if (.headRepositoryOwner.login // "") != "" and (.headRepository.name // "") != ""
   then (.headRepositoryOwner.login + "/" + .headRepository.name) else $repo end) as $hr
  | {
  id: (.number|tostring), title, body: (.body // ""),
  state: (if .state=="MERGED" then "merged" elif .state=="CLOSED" then "closed" else "open" end),
  base: .baseRefName, head: .headRefName, base_sha: (.baseRefOid // null), head_sha: (.headRefOid // null),
  head_repo: $hr, head_repo_url: ("https://github.com/" + $hr + ".git"), is_fork: (.isCrossRepository // false),
  url, created_at: .createdAt, merged_at: .mergedAt, closed_at: .closedAt,
  additions, deletions, changed_files: .changedFiles,
  review_decision: (if .reviewDecision=="APPROVED" then "approved" elif .reviewDecision=="CHANGES_REQUESTED" then "changes_requested" else "pending" end),
  author: (.author.login // null), platform: "github"}')"
