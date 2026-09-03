#!/usr/bin/env bash
# publish.sh — push a local spec and its tickets to the platform through the adapter
# contract, wire the blocking edges, and write the tracker ids back into the files.
#
#   publish.sh <feature-dir> [--platform github|azure] [--dry-run] [--mock] [--spec-only] [--tickets-only]
#
# Input layout (what /mattpocock-skills:to-spec and /to-tickets write with the
# local-markdown tracker, and what ai-sdlc stores under .sdlc/specs and .sdlc/tickets):
#   <feature-dir>/spec.md                 the spec
#   <feature-dir>/issues/NN-<slug>.md     one ticket per file, "Blocked by:" line names NN numbers
#
# Idempotent through <feature-dir>/publish-manifest.json: items already published are
# skipped, edges are re-applied (the contract makes repeated links a no-op). Each file
# gets a first-line marker `<!-- sdlc-publish: id=… url=… platform=… -->` that later
# stages read to stay traceable.
set -u
. "${0%/*}/../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"
BIN="$SDLC_PLUGIN_ROOT/bin/sdlc-platform"

dir=""; platform_args=(); only=""
while [ $# -gt 0 ]; do
  case "$1" in
    --platform) platform_args=(--platform "$2"); shift 2 ;;
    --dry-run) export SDLC_DRY_RUN=1; shift ;;
    --mock) export SDLC_PLATFORM_MOCK=1; shift ;;
    --spec-only) only=spec; shift ;;
    --tickets-only) only=tickets; shift ;;
    -*) sdlc_die 2 "publish.sh: unknown option $1" ;;
    *) dir="$1"; shift ;;
  esac
done
[ -n "$dir" ] && [ -d "$dir" ] || sdlc_die 2 "publish.sh <feature-dir> [--platform github|azure] [--dry-run]"
dir="${dir%/}"
spec="$dir/spec.md"; manifest="$dir/publish-manifest.json"
[ -f "$manifest" ] || echo '{"spec":null,"tickets":{},"links":[]}' >"$manifest"

platform=$("$BIN" "${platform_args[@]+"${platform_args[@]}"}" platform_detect 2>/dev/null || true)
[ -n "$platform" ] || platform="${platform_args[1]:-${SDLC_PLATFORM:-}}"
[ -n "$platform" ] || sdlc_die 3 "cannot determine the platform; pass --platform github|azure"
platform_args=(--platform "$platform")

marker_get() {  # marker_get <file> <key>
  local first; IFS= read -r first <"$1" || true
  [[ "$first" =~ \<!--\ sdlc-publish:.*[[:space:]]$2=([^[:space:]]+) ]] && printf '%s' "${BASH_REMATCH[1]}"
}
marker_set() {  # marker_set <file> <id> <url>
  local f="$1" tmp="$1.tmp.$$" first
  IFS= read -r first <"$f" || first=""
  { printf '<!-- sdlc-publish: id=%s url=%s platform=%s -->\n' "$2" "$3" "$platform"
    if [[ "$first" =~ ^\<!--\ sdlc-publish: ]]; then tail -n +2 "$f"; else cat "$f"; fi; } >"$tmp" && mv "$tmp" "$f"
}
title_of() {  # first heading, without leading "# " and an "NN: " prefix
  local t; t=$(grep -m1 -E '^# ' "$1" | sed -e 's/^# *//' -e 's/^[0-9][0-9]*: *//')
  [ -n "$t" ] || t="${1##*/}"; printf '%s' "$t"
}
strip_marker_to() {  # body without our marker line
  local f="$1" out="$2" first; IFS= read -r first <"$f" || first=""
  if [[ "$first" =~ ^\<!--\ sdlc-publish: ]]; then tail -n +2 "$f" >"$out"; else cp "$f" "$out"; fi
}
labels_of() {  # Status: line -> label, default ready-for-agent
  local s; s=$(grep -m1 -iE '^\*\*Status:\*\*|^Status:' "$1" | sed -E 's/^\**Status:\**[[:space:]]*//' | tr -d '\r')
  printf '%s' "${s:-ready-for-agent}"
}
blockers_of() {  # NN numbers named on the "Blocked by" line
  grep -m1 -iE '^\*\*Blocked by:\*\*|^Blocked by:' "$1" | sed -E 's/^\**Blocked by:\**//' | grep -oE '(^|[^0-9])[0-9]{2}([^0-9]|$)' | grep -oE '[0-9]{2}' | sort -u
}

created=0; linked=0; skipped=0
spec_id=$(jq -r '.spec.id // empty' "$manifest")

if [ "$only" != tickets ] && [ -f "$spec" ]; then
  if [ -n "$spec_id" ]; then skipped=$((skipped+1)); sdlc_log "spec already published as $spec_id"
  else
    body=$(sdlc_tmpfile .md); strip_marker_to "$spec" "$body"
    res=$("$BIN" "${platform_args[@]}" work_item_create "$(title_of "$spec")" "$body" --labels "spec,ready-for-agent") || { rm -f "$body"; sdlc_die 1 "publishing the spec failed"; }
    rm -f "$body"
    if [ "${SDLC_DRY_RUN:-0}" != 1 ]; then
      spec_id=$(printf '%s' "$res" | jq -r .id); spec_url=$(printf '%s' "$res" | jq -r .url)
      jq -c --arg id "$spec_id" --arg url "$spec_url" --arg p "$platform" '.platform=$p | .spec={id:$id,url:$url}' "$manifest" >"$manifest.tmp" && mv "$manifest.tmp" "$manifest"
      marker_set "$spec" "$spec_id" "$spec_url"; created=$((created+1))
    else printf '%s\n' "$res"; fi
  fi
fi

declare -A ticket_id=()
if [ "$only" != spec ] && [ -d "$dir/issues" ]; then
  for f in "$dir"/issues/[0-9][0-9]-*.md; do
    [ -f "$f" ] || continue
    nn="${f##*/}"; nn="${nn:0:2}"
    existing=$(jq -r --arg nn "$nn" '.tickets[$nn].id // empty' "$manifest")
    if [ -n "$existing" ]; then ticket_id[$nn]="$existing"; skipped=$((skipped+1)); continue; fi
    body=$(sdlc_tmpfile .md); strip_marker_to "$f" "$body"
    parent_args=(); [ -n "$spec_id" ] && parent_args=(--parent "$spec_id")
    res=$("$BIN" "${platform_args[@]}" work_item_create "$(title_of "$f")" "$body" --labels "$(labels_of "$f")" "${parent_args[@]+"${parent_args[@]}"}") || { rm -f "$body"; sdlc_die 1 "publishing ticket $nn failed"; }
    rm -f "$body"
    if [ "${SDLC_DRY_RUN:-0}" != 1 ]; then
      tid=$(printf '%s' "$res" | jq -r .id); turl=$(printf '%s' "$res" | jq -r .url)
      ticket_id[$nn]="$tid"
      jq -c --arg nn "$nn" --arg id "$tid" --arg url "$turl" --arg f "${f##*/}" '.tickets[$nn]={id:$id,url:$url,file:$f}' "$manifest" >"$manifest.tmp" && mv "$manifest.tmp" "$manifest"
      marker_set "$f" "$tid" "$turl"; created=$((created+1))
    else printf '%s\n' "$res"; fi
  done
  # second pass: blocking edges need every id to exist first
  for f in "$dir"/issues/[0-9][0-9]-*.md; do
    [ -f "$f" ] || continue
    nn="${f##*/}"; nn="${nn:0:2}"; to="${ticket_id[$nn]:-}"
    [ -n "$to" ] || continue
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      from="${ticket_id[$b]:-}"
      [ -n "$from" ] || { sdlc_log "ticket $nn is blocked by $b, which has no published id yet"; continue; }
      "$BIN" "${platform_args[@]}" work_item_link "$from" "$to" --type blocks >/dev/null || sdlc_die 1 "linking $b -> $nn failed"
      linked=$((linked+1))
      if [ "${SDLC_DRY_RUN:-0}" != 1 ]; then
        jq -c --arg f "$from" --arg t "$to" '.links = ((.links // []) + [{from:$f,to:$t,type:"blocks"}] | unique)' "$manifest" >"$manifest.tmp" && mv "$manifest.tmp" "$manifest"
      fi
    done < <(blockers_of "$f")
  done
fi

[ "${SDLC_DRY_RUN:-0}" = 1 ] || jq -cn --arg p "$platform" --arg d "$dir" --argjson c "$created" --argjson l "$linked" --argjson s "$skipped" --arg m "$manifest" \
  '{platform:$p,feature_dir:$d,created:$c,linked:$l,skipped:$s,manifest:$m}'
