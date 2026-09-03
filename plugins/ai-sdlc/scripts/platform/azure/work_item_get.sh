#!/usr/bin/env bash
# work_item_get (Azure DevOps): normalised work item JSON.
set -u
export SDLC_PLATFORM=azure
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
id="${1:-}"; [[ "$id" =~ ^[0-9]+$ ]] || usage_die "work_item_get <id>"
require_az; az_context
raw=$(cli az boards work-item show --id "$id" "${AZ_ARGS[@]}" -o json) || sdlc_die 1 "az boards work-item show $id failed"
state=$(az_state "$(printf '%s' "$raw" | jq -r '.fields["System.State"] // ""')")
# description is HTML: reduce it to text for the body field
text=$(printf '%s' "$raw" | jq -r '.fields["System.Description"] // ""' | sed -e 's#<br */\?>#\n#g' -e 's#</p>#\n#g' -e 's#</li>#\n#g' -e 's#<[^>]*>##g' -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\&/g' -e 's/&#9744;/[ ]/g' -e 's/&#9745;/[x]/g')
out_json "$(printf '%s' "$raw" | jq -c --arg state "$state" --arg text "$text" '{
  id: (.id|tostring), title: (.fields["System.Title"] // ""), body: $text, state: $state,
  labels: ((.fields["System.Tags"] // "") | split(";") | map(ltrimstr(" ") | rtrimstr(" ")) | map(select(length>0))),
  url: (._links.html.href // .url), created_at: (.fields["System.CreatedDate"] // null),
  closed_at: (.fields["Microsoft.VSTS.Common.ClosedDate"] // null),
  assignees: ([.fields["System.AssignedTo"] | select(. != null) | (.uniqueName // .displayName // .)]),
  platform: "azure"}')"
