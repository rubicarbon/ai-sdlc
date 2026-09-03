#!/usr/bin/env bash
# work_item_create (GitHub): create an issue from a Markdown body file.
#   work_item_create <title> <body-file> [--labels a,b] [--type T] [--parent ID]
set -u
export SDLC_PLATFORM=github
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"

title="${1:-}"; body="${2:-}"; shift 2 2>/dev/null || usage_die "work_item_create <title> <body-file> [--labels a,b] [--type T] [--parent ID]"
labels=""; parent=""
while [ $# -gt 0 ]; do
  case "$1" in
    --labels) labels="${2:-}"; shift 2 ;;
    --type) shift 2 ;;                      # GitHub issues have no type; accepted for contract parity
    --parent) parent="${2:-}"; shift 2 ;;
    *) usage_die "work_item_create: unknown argument '$1'" ;;
  esac
done
[ -n "$title" ] && [ -f "$body" ] || usage_die "work_item_create <title> <body-file> ..."
require_gh
repo=$(gh_repo)

label_args=()
if [ -n "$labels" ]; then
  IFS=',' read -ra ls <<<"$labels"
  for l in "${ls[@]}"; do
    l="${l# }"; [ -z "$l" ] && continue
    gh label create "$l" --repo "$repo" --force >/dev/null 2>&1 || true   # idempotent; missing labels would fail issue creation
    label_args+=(--label "$l")
  done
fi

url=$(cli gh issue create --repo "$repo" --title "$title" --body-file "$body" "${label_args[@]+"${label_args[@]}"}") || sdlc_die 1 "gh issue create failed"
id="${url##*/}"
[[ "$id" =~ ^[0-9]+$ ]] || sdlc_die 1 "unexpected gh output: $url"

if [ -n "$parent" ]; then
  db_id=$(gh api "repos/$repo/issues/$id" --jq .id 2>/dev/null) || db_id=""
  if [ -z "$db_id" ] || ! gh api --method POST "repos/$repo/issues/$parent/sub_issues" -F "sub_issue_id=$db_id" >/dev/null 2>&1; then
    tmp=$(sdlc_tmpfile .md); { printf 'Part of #%s\n\n' "$parent"; cat "$body"; } >"$tmp"
    gh issue edit "$id" --repo "$repo" --body-file "$tmp" >/dev/null 2>&1 || true
    rm -f "$tmp"
  fi
fi

out_json "$(jq -cn --arg id "$id" --arg url "$url" '{id:$id,url:$url,platform:"github"}')"
