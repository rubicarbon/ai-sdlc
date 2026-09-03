#!/usr/bin/env bash
# pr_comment (GitHub): comment on a pull request from a Markdown file.
set -u
export SDLC_PLATFORM=github
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
id="${1:-}"; body="${2:-}"
[[ "$id" =~ ^[0-9]+$ ]] && [ -f "$body" ] || usage_die "pr_comment <id> <body-file>"
require_gh
repo=$(gh_repo)
url=$(cli gh pr comment "$id" --repo "$repo" --body-file "$body") || sdlc_die 1 "gh pr comment $id failed"
cid="${url##*issuecomment-}"; [ "$cid" = "$url" ] && cid=""
out_json "$(jq -cn --arg id "$id" --arg c "$cid" '{id:$id,comment_id:(if $c=="" then null else $c end),platform:"github"}')"
