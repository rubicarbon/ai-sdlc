#!/usr/bin/env bash
# work_item_link (Azure DevOps): native links.
#   blocks  -> Successor (System.LinkTypes.Dependency-Forward) from <from> to <to>
#   parent  -> Parent on <to> pointing at <from>
#   related -> Related
# A link that already exists (TF201036) is success: the contract is idempotent.
set -u
export SDLC_PLATFORM=azure
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
from="${1:-}"; to="${2:-}"; shift 2 2>/dev/null || usage_die "work_item_link <from-id> <to-id> --type blocks|parent|related"
type=""
while [ $# -gt 0 ]; do case "$1" in --type) type="${2:-}"; shift 2 ;; *) usage_die "work_item_link: unknown argument '$1'" ;; esac; done
[[ "$from" =~ ^[0-9]+$ && "$to" =~ ^[0-9]+$ ]] || usage_die "work_item_link <from-id> <to-id> --type blocks|parent|related"
case "$type" in
  blocks)  src="$from"; rel="successor"; dst="$to" ;;
  parent)  src="$to";   rel="parent";    dst="$from" ;;
  related) src="$from"; rel="related";   dst="$to" ;;
  *) usage_die "work_item_link: --type must be blocks, parent or related (got '${type:-none}')" ;;
esac
require_az; az_context
if ! err=$(cli az boards work-item relation add --id "$src" --relation-type "$rel" --target-id "$dst" "${AZ_ARGS[@]}" -o json 2>&1 >/dev/null); then
  [[ "$err" =~ already\ exists|TF201036 ]] || sdlc_die 1 "az boards work-item relation add failed: $err"
fi
out_json "$(jq -cn --arg f "$from" --arg t "$to" --arg ty "$type" '{from:$f,to:$t,type:$ty,native:true,platform:"azure"}')"
