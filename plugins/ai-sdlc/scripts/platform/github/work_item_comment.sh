#!/usr/bin/env bash
# work_item_comment (GitHub): comment on an issue from a Markdown file.
set -u
export SDLC_PLATFORM=github
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
id="${1:-}"; body="${2:-}"
[[ "$id" =~ ^[0-9]+$ ]] && [ -f "$body" ] || usage_die "work_item_comment <id> <body-file>"
require_gh
repo=$(gh_repo)
url=$(cli gh issue comment "$id" --repo "$repo" --body-file "$body") || sdlc_die 1 "gh issue comment $id failed"
cid="${url##*issuecomment-}"; [ "$cid" = "$url" ] && cid=""
out_json "$(jq -cn --arg id "$id" --arg c "$cid" '{id:$id,comment_id:(if $c=="" then null else $c end),platform:"github"}')"
