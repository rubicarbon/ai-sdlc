#!/usr/bin/env bash
# work_item_get (GitHub): normalised issue JSON.
set -u
export SDLC_PLATFORM=github
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
id="${1:-}"; [[ "$id" =~ ^[0-9]+$ ]] || usage_die "work_item_get <id>"
require_gh
repo=$(gh_repo)
raw=$(cli gh issue view "$id" --repo "$repo" --json number,title,body,state,labels,url,createdAt,closedAt,assignees) || sdlc_die 1 "gh issue view $id failed"
out_json "$(printf '%s' "$raw" | jq -c '{
  id: (.number|tostring), title, body: (.body // ""),
  state: (if (.state|ascii_downcase)=="closed" then "closed" else "open" end),
  labels: [(.labels // [])[] | .name], url, created_at: .createdAt, closed_at: .closedAt,
  assignees: [(.assignees // [])[] | .login], platform: "github"}')"
