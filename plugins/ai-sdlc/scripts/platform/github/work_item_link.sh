#!/usr/bin/env bash
# work_item_link (GitHub): blocks -> issue dependencies API, parent -> sub-issues API,
# related -> body line. Falls back to body lines when an API is unavailable.
#   work_item_link <from-id> <to-id> --type blocks|parent|related
set -u
export SDLC_PLATFORM=github
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
from="${1:-}"; to="${2:-}"; shift 2 2>/dev/null || usage_die "work_item_link <from-id> <to-id> --type blocks|parent|related"
type=""
while [ $# -gt 0 ]; do case "$1" in --type) type="${2:-}"; shift 2 ;; *) usage_die "work_item_link: unknown argument '$1'" ;; esac; done
[[ "$from" =~ ^[0-9]+$ && "$to" =~ ^[0-9]+$ ]] || usage_die "work_item_link <from-id> <to-id> --type blocks|parent|related"
case "$type" in blocks|parent|related) ;; *) usage_die "work_item_link: --type must be blocks, parent or related (got '${type:-none}')" ;; esac
require_gh
repo=$(gh_repo)

# add_line <issue> <line>: idempotently add a line to the top of an issue body
add_line() {
  local n="$1" line="$2" body tmp
  body=$(gh issue view "$n" --repo "$repo" --json body --jq .body 2>/dev/null) || body=""
  case "$body" in *"$line"*) return 0 ;; esac
  tmp=$(sdlc_tmpfile .md); { printf '%s\n\n' "$line"; printf '%s\n' "$body"; } >"$tmp"
  gh issue edit "$n" --repo "$repo" --body-file "$tmp" >/dev/null 2>&1; local rc=$?
  rm -f "$tmp"; return $rc
}

native=false
case "$type" in
  blocks)
    db=$(gh api "repos/$repo/issues/$from" --jq .id 2>/dev/null) || db=""
    err=""
    if [ -n "$db" ]; then
      if err=$(gh api --method POST "repos/$repo/issues/$to/dependencies/blocked_by" -F "issue_id=$db" 2>&1 >/dev/null); then native=true
      elif [[ "$err" =~ 422|already ]]; then native=true          # duplicate edge: already in place
      fi
    fi
    if [ "$native" = false ]; then
      add_line "$to" "Blocked by: #$from" || sdlc_die 1 "could not record blocking edge #$from -> #$to: $err"
    fi ;;
  parent)
    db=$(gh api "repos/$repo/issues/$to" --jq .id 2>/dev/null) || db=""
    err=""
    if [ -n "$db" ]; then
      if err=$(gh api --method POST "repos/$repo/issues/$from/sub_issues" -F "sub_issue_id=$db" 2>&1 >/dev/null); then native=true
      elif [[ "$err" =~ 422|already ]]; then native=true
      fi
    fi
    if [ "$native" = false ]; then
      add_line "$to" "Part of #$from" || sdlc_die 1 "could not record parent #$from for #$to: $err"
    fi ;;
  related)
    add_line "$to" "Related: #$from" || sdlc_die 1 "could not record relation #$from -> #$to" ;;
esac
out_json "$(jq -cn --arg f "$from" --arg t "$to" --arg ty "$type" --argjson n "$native" '{from:$f,to:$t,type:$ty,native:$n,platform:"github"}')"
