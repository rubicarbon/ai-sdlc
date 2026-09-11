#!/usr/bin/env bash
# status.sh — the launch lifecycle of the local pull-request review (review.runner local).
#
#   status.sh new --branch <b> [--pr <id>] [--launcher <path>] [--trigger pr_create|push|manual]
#   status.sh set <launch_id> <state> [detail]
#   status.sh attach <launch_id> [--pr <id>] [--head-sha <sha>] [--base-sha <sha>] [--report <path>]
#   status.sh get (--launch <id> | --pr <id> | --branch <b> | --map <b> | --all) [--field <name>]
#   status.sh map --branch <b> --pr <id> [--sha <sha>]
#   status.sh lock <pr|local> <sha12> <launch_id>        exit 1 when another live launch holds it
#   status.sh unlock <pr|local> <sha12>
#   status.sh sweep
#   status.sh is_terminal <state>
#
# Everything lives under <artifacts>/tmp/review/ (gitignored by init): one launch-<id>.json per
# launch, one branch-<slug>.json per branch that has a pull request, one lock-<pr>-<sha12>/
# directory per review in progress. The hook writes "requested", the launcher script "started",
# /ai-sdlc:sdlc-review "running" -> "saved" -> "posted" (or "saved" as the end state on platform
# none), scripts/review/finalize.sh the failure states. Intermediate states on a hosted platform:
# requested started running saved. Terminal states: posted, saved (platform none only),
# failed <reason>, stale, skipped duplicate, abandoned, timeout. `sweep` turns a "requested" launch
# older than 5 minutes into "timeout" and a started/running/saved launch older than
# SDLC_REVIEW_STALE_MINUTES (default 120) into "abandoned", and removes locks whose holder is
# terminal; a closed terminal window is therefore detected eventually, not immediately.
# `get --pr` / `get --branch` return the newest launch (launch ids start with a UTC timestamp);
# `get --branch` falls back to the branch mapping when no launch exists; `get --map <b>` reads
# the mapping only ({branch, pr, last_sha}). `--field` prints one field raw (empty when
# absent) for shell callers.
set -u
. "${0%/*}/../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"
. "$SDLC_PLUGIN_ROOT/scripts/_project.sh"
[ -n "${SDLC_PROJECT_DIR:-}" ] || sdlc_die 2 "status.sh: no sdlc.config.json found (not an sdlc project)"

art=$(sdlc_artifacts_dir); dir="$art/tmp/review"
platform=$(sdlc_config .platform none)
usage() { sdlc_die 2 "status.sh new|set|attach|get|map|lock|unlock|sweep|is_terminal ... (see the header of scripts/review/status.sh)"; }
slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
now_epoch() { date +%s; }
launch_file() { printf '%s/launch-%s.json' "$dir" "$1"; }
map_file() { printf '%s/branch-%s.json' "$dir" "$(slug "$1")"; }
lock_dir() { printf '%s/lock-%s-%s' "$dir" "$1" "$2"; }

# is_terminal <state>: saved ends a review only on platform none (nothing to post there)
is_terminal() {
  case "$1" in
    posted|stale|abandoned|timeout) return 0 ;;
    failed|failed\ *|skipped\ *) return 0 ;;
    saved) [ "$platform" = none ] ;;
    *) return 1 ;;
  esac
}

write_json() {  # write_json <file> <json> : atomic replace
  local tmp="$1.tmp.$$"; printf '%s\n' "$2" >"$tmp" && mv -f "$tmp" "$1"
}

state_of() {  # state_of <launch file> : builtins only (a fork costs 100-300 ms on Windows)
  local c; c=$(<"$1") 2>/dev/null || return 0
  [[ "$c" =~ \"state\":\"([^\"]*)\" ]] && printf '%s' "${BASH_REMATCH[1]}"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  new)
    branch=""; pr=""; launcher=""; trigger=manual
    while [ $# -gt 0 ]; do
      case "$1" in
        --branch) branch="${2:-}"; shift 2 ;; --pr) pr="${2:-}"; shift 2 ;;
        --launcher) launcher="${2:-}"; shift 2 ;; --trigger) trigger="${2:-manual}"; shift 2 ;;
        *) usage ;;
      esac
    done
    mkdir -p "$dir" || sdlc_die 1 "status.sh: cannot create $dir"
    id="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
    now=$(now_epoch)
    write_json "$(launch_file "$id")" "$(jq -cn --arg id "$id" --arg pr "$pr" --arg b "$branch" --arg l "$launcher" --arg t "$trigger" \
      --arg at "$(sdlc_iso_now)" --argjson e "$now" \
      '{launch_id:$id, state:"requested", detail:"", pr:(if $pr=="" then null else $pr end), branch:(if $b=="" then null else $b end),
        launcher:(if $l=="" then null else $l end), trigger:$t, head_sha:null, base_sha:null, report:null,
        at:$at, at_epoch:$e, updated_epoch:$e, history:[{state:"requested", detail:"", at:$at}]}')"
    printf '%s\n' "$id" ;;
  set)
    id="${1:-}"; state="${2:-}"; detail="${3:-}"
    [ -n "$id" ] && [ -n "$state" ] || usage
    f=$(launch_file "$id"); [ -f "$f" ] || sdlc_die 1 "status.sh: unknown launch $id"
    write_json "$f" "$(jq -c --arg s "$state" --arg d "$detail" --arg at "$(sdlc_iso_now)" --argjson e "$(now_epoch)" \
      '.state=$s | .detail=$d | .updated_epoch=$e | .history += [{state:$s, detail:$d, at:$at}]' "$f")" ;;
  attach)
    id="${1:-}"; shift || true; [ -n "$id" ] || usage
    f=$(launch_file "$id"); [ -f "$f" ] || sdlc_die 1 "status.sh: unknown launch $id"
    filter='.'
    while [ $# -gt 0 ]; do
      case "$1" in
        --pr) filter="$filter | .pr=\"$(sdlc_json_escape "${2:-}")\""; shift 2 ;;
        --head-sha) filter="$filter | .head_sha=\"$(sdlc_json_escape "${2:-}")\""; shift 2 ;;
        --base-sha) filter="$filter | .base_sha=\"$(sdlc_json_escape "${2:-}")\""; shift 2 ;;
        --report) filter="$filter | .report=\"$(sdlc_json_escape "${2:-}")\""; shift 2 ;;
        *) usage ;;
      esac
    done
    write_json "$f" "$(jq -c "$filter | .updated_epoch=$(now_epoch)" "$f")" ;;
  get)
    mode=""; key=""; field=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --launch) mode=launch; key="${2:-}"; shift 2 ;; --pr) mode='pr'; key="${2:-}"; shift 2 ;;
        --branch) mode=branch; key="${2:-}"; shift 2 ;; --map) mode=map; key="${2:-}"; shift 2 ;; --all) mode=all; shift ;;
        --field) field="${2:-}"; shift 2 ;;
        *) usage ;;
      esac
    done
    [ -n "$mode" ] || usage
    [ -d "$dir" ] || { [ -n "$field" ] && exit 1; [ "$mode" = all ] && { echo '[]'; exit 0; }; exit 1; }
    result=""
    case "$mode" in
      all) jq -cs 'sort_by(.launch_id)' "$dir"/launch-*.json 2>/dev/null || echo '[]'; exit 0 ;;
      launch) f=$(launch_file "$key"); [ -f "$f" ] && result=$(jq -c . "$f") ;;
      map) m=$(map_file "$key"); [ -f "$m" ] && result=$(jq -c . "$m") ;;
      pr) result=$(jq -cs --arg pr "$key" '[.[] | select(.pr == $pr)] | sort_by(.launch_id) | last // empty' "$dir"/launch-*.json 2>/dev/null) ;;
      branch)
        result=$(jq -cs --arg b "$key" '[.[] | select(.branch == $b)] | sort_by(.launch_id) | last // empty' "$dir"/launch-*.json 2>/dev/null)
        if [ -z "$result" ] || [ "$result" = null ]; then
          m=$(map_file "$key"); [ -f "$m" ] && result=$(jq -c . "$m")
        fi ;;
    esac
    [ -n "$result" ] && [ "$result" != null ] || exit 1
    if [ -n "$field" ]; then jq -r --arg f "$field" '.[$f] // empty' <<<"$result"; else printf '%s\n' "$result"; fi ;;
  map)
    branch=""; pr=""; sha=""
    while [ $# -gt 0 ]; do
      case "$1" in --branch) branch="${2:-}"; shift 2 ;; --pr) pr="${2:-}"; shift 2 ;; --sha) sha="${2:-}"; shift 2 ;; *) usage ;; esac
    done
    [ -n "$branch" ] && [ -n "$pr" ] || usage
    mkdir -p "$dir" || sdlc_die 1 "status.sh: cannot create $dir"
    m=$(map_file "$branch"); prev='{}'; [ -f "$m" ] && prev=$(jq -c . "$m" 2>/dev/null || echo '{}')
    write_json "$m" "$(jq -cn --argjson p "$prev" --arg b "$branch" --arg pr "$pr" --arg sha "$sha" --arg at "$(sdlc_iso_now)" \
      '$p + {branch:$b, pr:$pr, updated:$at} | .last_sha = (if $sha=="" then ($p.last_sha // null) else $sha end)')" ;;
  lock)
    pr="${1:-}"; sha12="${2:-}"; id="${3:-}"; [ -n "$pr" ] && [ -n "$sha12" ] && [ -n "$id" ] || usage
    mkdir -p "$dir" || sdlc_die 1 "status.sh: cannot create $dir"
    l=$(lock_dir "$pr" "$sha12")
    if mkdir "$l" 2>/dev/null; then printf '%s\n' "$id" >"$l/holder"; exit 0; fi
    holder=$(cat "$l/holder" 2>/dev/null || true)
    if [ -n "$holder" ] && [ "$holder" != "$id" ] && [ -f "$(launch_file "$holder")" ] && ! is_terminal "$(state_of "$(launch_file "$holder")")"; then
      printf '%s\n' "$holder"; exit 1
    fi
    printf '%s\n' "$id" >"$l/holder"; exit 0 ;;
  unlock)
    pr="${1:-}"; sha12="${2:-}"; [ -n "$pr" ] && [ -n "$sha12" ] || usage
    rm -rf "$(lock_dir "$pr" "$sha12")"; exit 0 ;;
  sweep)
    [ -d "$dir" ] || exit 0
    now=$(now_epoch); stale_min="${SDLC_REVIEW_STALE_MINUTES:-120}"
    case "$stale_min" in ''|*[!0-9]*) stale_min=120 ;; esac
    files=("$dir"/launch-*.json)
    if [ -f "${files[0]}" ]; then
      # one jq over every launch file; only the launches that change are written back
      while IFS=$'\t' read -r lid lstate ldetail; do
        [ -n "$lid" ] || continue
        bash "$0" set "$lid" "$lstate" "$ldetail"
      done < <(jq -rs --argjson now "$now" --argjson stale $(( stale_min * 60 )) --arg p "$platform" --arg sm "$stale_min" '
        .[] | . as $l | (($l.updated_epoch // $l.at_epoch // 0) | tonumber) as $u
        | if $l.state == "requested" and ($now - $u) > 300 then
            [$l.launch_id, "timeout", "no launcher acknowledged the launch within 5 minutes"]
          elif ($l.state | IN("started", "running")) and ($now - $u) > $stale then
            [$l.launch_id, "abandoned", "no progress for \($sm) minutes (window closed or session ended without finishing)"]
          elif $l.state == "saved" and $p != "none" and ($now - $u) > $stale then
            [$l.launch_id, "abandoned", "no progress for \($sm) minutes (window closed or session ended without finishing)"]
          else empty end | @tsv' "${files[@]}" 2>/dev/null)
    fi
    for l in "$dir"/lock-*/; do
      [ -d "$l" ] || continue
      holder=$(cat "$l/holder" 2>/dev/null || true)
      if [ -z "$holder" ] || [ ! -f "$(launch_file "$holder")" ] || is_terminal "$(state_of "$(launch_file "$holder")")"; then rm -rf "$l"; fi
    done
    exit 0 ;;
  is_terminal) [ -n "${1:-}" ] || usage; is_terminal "$1" ;;
  *) usage ;;
esac
