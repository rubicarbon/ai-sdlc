#!/usr/bin/env bash
# work_item_comment (Azure DevOps): add a discussion comment from a Markdown file.
# The CLI does not return the comment id, so comment_id is null.
set -u
export SDLC_PLATFORM=azure
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
id="${1:-}"; body="${2:-}"
[[ "$id" =~ ^[0-9]+$ ]] && [ -f "$body" ] || usage_die "work_item_comment <id> <body-file>"
require_az; az_context
html=$(md_to_html "$body")
cli az boards work-item update --id "$id" --discussion "$html" "${AZ_ARGS[@]}" -o json >/dev/null || sdlc_die 1 "az boards work-item update --discussion failed for $id"
out_json "$(jq -cn --arg id "$id" '{id:$id,comment_id:null,platform:"azure"}')"
