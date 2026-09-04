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
# Platform: an explicit --platform wins and must be github or azure (exit 2 otherwise).
# Without it the platform is resolved in this order: $SDLC_PLATFORM, then "platform" in
# sdlc.config.json (unless it is both or none), then the git remote; exit 3 when nothing decides.
#
# Idempotent through <feature-dir>/publish-manifest.json: items already published are
# skipped, edges are re-applied (the contract makes repeated links a no-op). The manifest
# records the platform the ids belong to. A manifest that records another platform, a
# manifest with published items but no platform field, or a file whose marker names another
# platform stops the run with exit 1 and an actionable message: ids are never guessed to live
# elsewhere. Each file gets a first-line marker `<!-- sdlc-publish: id=… url=… platform=… -->`
# that later stages read to stay traceable.
#
# --dry-run prints the CLI commands the adapters would run and writes nothing at all: no
# manifest, no markers, no temporary file inside the feature directory.
set -u
. "${0%/*}/../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"
BIN="$SDLC_PLUGIN_ROOT/bin/sdlc-platform"

dir=""; platform=""; only=""; dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --platform) platform="${2:-}"; shift 2 ;;
    --dry-run) export SDLC_DRY_RUN=1; dry=1; shift ;;
    --mock) export SDLC_PLATFORM_MOCK=1; shift ;;
    --spec-only) only=spec; shift ;;
    --tickets-only) only=tickets; shift ;;
    -*) sdlc_die 2 "publish.sh: unknown option $1" ;;
    *) dir="$1"; shift ;;
  esac
done
[ -n "$dir" ] && [ -d "$dir" ] || sdlc_die 2 "publish.sh <feature-dir> [--platform github|azure] [--dry-run]"
dir="${dir%/}"
spec="$dir/spec.md"; manifest_file="$dir/publish-manifest.json"

# ------------------------------------------------------------------ platform
if [ -n "$platform" ]; then
  case "$platform" in
    github|azure) ;;
    *) sdlc_die 2 "publish.sh: --platform must be github or azure (got '$platform')" ;;
  esac
else
  platform="${SDLC_PLATFORM:-}"
  case "$platform" in
    github|azure) ;;
    ''|both|auto) platform="" ;;
    none) sdlc_die 3 "not supported on this platform: SDLC_PLATFORM is 'none' (local artifacts only); pass --platform github|azure to publish anyway" ;;
    *) sdlc_die 2 "publish.sh: SDLC_PLATFORM must be github or azure (got '$platform')" ;;
  esac
  if [ -z "$platform" ]; then
    SDLC_PROJECT_OPTIONAL=1 . "$SDLC_PLUGIN_ROOT/scripts/_project.sh"
    if [ -n "${SDLC_CONFIG:-}" ]; then
      cfg_platform=$(sdlc_config '.platform' '')
      case "$cfg_platform" in github|azure) platform="$cfg_platform" ;; esac
    fi
  fi
  if [ -z "$platform" ]; then
    platform=$(bash "$SDLC_PLUGIN_ROOT/scripts/platform/_detect.sh" 2>/dev/null) || platform=""
    case "$platform" in github|azure) ;; *) sdlc_die 3 "cannot determine the platform: no --platform, SDLC_PLATFORM is unset, sdlc.config.json does not name github or azure, and the git remote is neither. Pass --platform github|azure" ;; esac
  fi
fi
platform_args=(--platform "$platform")

# ------------------------------------------------------------------ manifest (in memory)
if [ -f "$manifest_file" ]; then
  manifest=$(jq -c . "$manifest_file" 2>/dev/null) || sdlc_die 1 "$manifest_file is not valid JSON; fix or remove it before publishing"
else
  manifest='{"spec":null,"tickets":{},"links":[]}'
fi
rec_platform=$(jq -r '.platform // empty' <<<"$manifest")
published=$(jq -r 'if (.spec != null) or ((.tickets // {}) | length) > 0 then "true" else "false" end' <<<"$manifest")
if [ -n "$rec_platform" ] && [ "$rec_platform" != "$platform" ]; then
  sdlc_die 1 "$manifest_file records platform '$rec_platform' but this run targets '$platform'. Re-run with --platform $rec_platform to continue on $rec_platform; to republish everything on $platform, move the manifest away and remove the '<!-- sdlc-publish' marker lines from spec.md and issues/*.md first."
fi
if [ -z "$rec_platform" ] && [ "$published" = true ]; then
  sdlc_die 1 "$manifest_file has published items but no \"platform\" field, so the tracker that holds those ids is unknown. Add \"platform\": \"github\" or \"platform\": \"azure\" to the manifest (whichever tracker the ids belong to) and re-run; the platform is never guessed."
fi
manifest=$(jq -c --arg p "$platform" '.platform = $p' <<<"$manifest")
save_manifest() {  # written only outside --dry-run, atomically
  [ $dry = 1 ] && return 0
  local tmp="$manifest_file.tmp.$$"
  jq . <<<"$manifest" >"$tmp" && mv "$tmp" "$manifest_file"
}

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

# a marker that names another platform means the file's ids live elsewhere: refuse
for f in "$spec" "$dir"/issues/[0-9][0-9]-*.md; do
  [ -f "$f" ] || continue
  mp=$(marker_get "$f" platform)
  if [ -n "$mp" ] && [ "$mp" != "$platform" ]; then
    sdlc_die 1 "$f carries a sdlc-publish marker for platform '$mp' but this run targets '$platform'. Re-run with --platform $mp, or remove the marker line (and the manifest entry) to republish the file on $platform."
  fi
done

created=0; linked=0; skipped=0
spec_id=$(jq -r '.spec.id // empty' <<<"$manifest")

if [ "$only" != tickets ] && [ -f "$spec" ]; then
  if [ -n "$spec_id" ]; then skipped=$((skipped+1)); sdlc_log "spec already published as $spec_id"
  else
    body=$(sdlc_tmpfile .md); strip_marker_to "$spec" "$body"
    res=$("$BIN" "${platform_args[@]}" work_item_create "$(title_of "$spec")" "$body" --labels "spec,ready-for-agent") || { rm -f "$body"; sdlc_die 1 "publishing the spec failed"; }
    rm -f "$body"
    if [ $dry = 0 ]; then
      spec_id=$(printf '%s' "$res" | jq -r .id); spec_url=$(printf '%s' "$res" | jq -r .url)
      [ -n "$spec_id" ] && [ "$spec_id" != null ] || sdlc_die 1 "the adapter returned no id for the spec: $res"
      manifest=$(jq -c --arg id "$spec_id" --arg url "$spec_url" '.spec = {id: $id, url: $url}' <<<"$manifest"); save_manifest
      marker_set "$spec" "$spec_id" "$spec_url"; created=$((created+1))
    else printf '%s\n' "$res"; fi
  fi
fi

declare -A ticket_id=()
if [ "$only" != spec ] && [ -d "$dir/issues" ]; then
  for f in "$dir"/issues/[0-9][0-9]-*.md; do
    [ -f "$f" ] || continue
    nn="${f##*/}"; nn="${nn:0:2}"
    existing=$(jq -r --arg nn "$nn" '.tickets[$nn].id // empty' <<<"$manifest")
    if [ -n "$existing" ]; then ticket_id[$nn]="$existing"; skipped=$((skipped+1)); continue; fi
    body=$(sdlc_tmpfile .md); strip_marker_to "$f" "$body"
    parent_args=(); [ -n "$spec_id" ] && parent_args=(--parent "$spec_id")
    res=$("$BIN" "${platform_args[@]}" work_item_create "$(title_of "$f")" "$body" --labels "$(labels_of "$f")" "${parent_args[@]+"${parent_args[@]}"}") || { rm -f "$body"; sdlc_die 1 "publishing ticket $nn failed"; }
    rm -f "$body"
    if [ $dry = 0 ]; then
      tid=$(printf '%s' "$res" | jq -r .id); turl=$(printf '%s' "$res" | jq -r .url)
      [ -n "$tid" ] && [ "$tid" != null ] || sdlc_die 1 "the adapter returned no id for ticket $nn: $res"
      ticket_id[$nn]="$tid"
      manifest=$(jq -c --arg nn "$nn" --arg id "$tid" --arg url "$turl" --arg f "${f##*/}" '.tickets[$nn] = {id: $id, url: $url, file: $f}' <<<"$manifest"); save_manifest
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
      if [ $dry = 0 ]; then
        manifest=$(jq -c --arg f "$from" --arg t "$to" '.links = ((.links // []) + [{from: $f, to: $t, type: "blocks"}] | unique)' <<<"$manifest"); save_manifest
      fi
    done < <(blockers_of "$f")
  done
fi

if [ $dry = 0 ]; then
  save_manifest   # also records the platform when nothing new was published
  jq -cn --arg p "$platform" --arg d "$dir" --argjson c "$created" --argjson l "$linked" --argjson s "$skipped" --arg m "$manifest_file" \
    '{platform:$p,feature_dir:$d,created:$c,linked:$l,skipped:$s,manifest:$m}'
fi
