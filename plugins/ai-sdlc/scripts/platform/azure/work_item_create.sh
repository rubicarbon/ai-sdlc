#!/usr/bin/env bash
# work_item_create (Azure DevOps): create a work item from a Markdown body file.
#   work_item_create <title> <body-file> [--labels a,b] [--type T] [--parent ID]
# The description is HTML (converted from Markdown); the raw Markdown is kept as
# the first discussion comment so nothing is lost.
set -u
export SDLC_PLATFORM=azure
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"

title="${1:-}"; body="${2:-}"; shift 2 2>/dev/null || usage_die "work_item_create <title> <body-file> [--labels a,b] [--type T] [--parent ID]"
labels=""; type=""; parent=""
while [ $# -gt 0 ]; do
  case "$1" in
    --labels) labels="${2:-}"; shift 2 ;;
    --type) type="${2:-}"; shift 2 ;;
    --parent) parent="${2:-}"; shift 2 ;;
    *) usage_die "work_item_create: unknown argument '$1'" ;;
  esac
done
[ -n "$title" ] && [ -f "$body" ] || usage_die "work_item_create <title> <body-file> ..."
require_az; az_context
[ -n "$type" ] || type=$(az_work_item_type)

html=$(md_to_html "$body")
field_args=()
if [ -n "$labels" ]; then tags="${labels//,/; }"; field_args=(--fields "System.Tags=$tags"); fi

raw=$(cli az boards work-item create --type "$type" --title "$title" --description "$html" "${field_args[@]+"${field_args[@]}"}" "${AZ_ARGS[@]}" -o json) || sdlc_die 1 "az boards work-item create failed"
id=$(printf '%s' "$raw" | jq -r '.id'); url=$(printf '%s' "$raw" | jq -r '._links.html.href // .url')
[[ "$id" =~ ^[0-9]+$ ]] || sdlc_die 1 "unexpected az output: ${raw:0:200}"

# keep the raw Markdown verbatim as the first comment
esc=$(sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$body")
az boards work-item update --id "$id" --discussion "<pre>$esc</pre>" "${AZ_ARGS[@]}" -o json >/dev/null 2>&1 || true

if [ -n "$parent" ]; then
  err=$(az boards work-item relation add --id "$id" --relation-type parent --target-id "$parent" "${AZ_ARGS[@]}" -o json 2>&1 >/dev/null) \
    || [[ "$err" =~ already\ exists|TF201036 ]] || sdlc_die 1 "could not link parent $parent: $err"
fi
out_json "$(jq -cn --arg id "$id" --arg url "$url" '{id:$id,url:$url,platform:"azure"}')"
