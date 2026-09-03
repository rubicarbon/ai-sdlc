#!/usr/bin/env bash
# pr_comment (Azure DevOps): post a new comment thread on a pull request via REST
# (the CLI has no PR comment command). Markdown is accepted by Azure Repos threads.
set -u
export SDLC_PLATFORM=azure
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
id="${1:-}"; body="${2:-}"
[[ "$id" =~ ^[0-9]+$ ]] && [ -f "$body" ] || usage_die "pr_comment <id> <body-file>"
require_az; az_context
payload=$(sdlc_tmpfile .json)
jq -cn --rawfile c "$body" '{comments:[{parentCommentId:0,content:$c,commentType:1}],status:1}' >"$payload"
uri="$AZ_ORG/$AZ_PROJECT/_apis/git/repositories/$AZ_REPO/pullRequests/$id/threads?api-version=7.1"
auth=(--resource 499b84ac-1321-427f-aa17-267ca6975798)   # Azure DevOps token audience
if [ -n "${AZURE_DEVOPS_EXT_PAT:-}" ]; then
  b64=$(printf ':%s' "$AZURE_DEVOPS_EXT_PAT" | base64 | tr -d '\n')
  auth=(--skip-authorization-header --headers "Authorization=Basic $b64")
fi
raw=$(cli az rest --method post --uri "$uri" --body "@$payload" --headers "Content-Type=application/json" "${auth[@]}" -o json 2>&1) || { rm -f "$payload"; sdlc_die 1 "az rest POST threads failed: ${raw:0:300}"; }
rm -f "$payload"
cid=$(printf '%s' "$raw" | jq -r '.id // empty' 2>/dev/null)
out_json "$(jq -cn --arg id "$id" --arg c "${cid:-}" '{id:$id,comment_id:(if $c=="" then null else $c end),platform:"azure"}')"
