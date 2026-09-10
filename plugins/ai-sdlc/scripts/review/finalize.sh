#!/usr/bin/env bash
# finalize.sh — validate, re-check the pull request head, post, then publish the local review.
#
#   finalize.sh --launch <id> --report <tmp file> --publish <final path> \
#               [--pr <id> --head-sha <sha>]
#
# Hosted platform (--pr given), in this order, each step recording its own failure state:
#   1. scripts/loop/validate-report.sh <tmp> --security --head <sha>   -> "failed validate: ..." exit 1
#   2. sdlc-platform pr_get <pr>: head_sha must still equal --head-sha  -> "**Status:** stale" written
#      into the tmp file, state "stale", exit 4 (nothing published: the next push launches a new
#      review)
#   3. sdlc-platform pr_comment <pr> <tmp>                                -> "failed post: ..." exit 1
#   4. atomic publish (mv) to --publish, state "posted", branch mapping last_sha updated, lock
#      released, exit 0.
# Platform none (no --pr): validate against HEAD, publish, state "saved" (the end state there).
# Nothing is ever published before validation and posting succeeded, so a file under
# <artifacts>/verify/ is always a complete, validated review; the ship gate reads only those.
set -u
. "${0%/*}/../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"
. "$SDLC_PLUGIN_ROOT/scripts/_project.sh"
[ -n "${SDLC_PROJECT_DIR:-}" ] || sdlc_die 2 "finalize.sh: no sdlc.config.json found (not an sdlc project)"
STATUS="$SDLC_PLUGIN_ROOT/scripts/review/status.sh"; BIN="$SDLC_PLUGIN_ROOT/bin/sdlc-platform"
usage() { sdlc_die 2 "finalize.sh --launch <id> --report <tmp> --publish <final> [--pr <id> --head-sha <sha>]"; }
launch=""; report=""; publish=""; pr=""; head=""
while [ $# -gt 0 ]; do
  case "$1" in
    --launch) launch="${2:-}"; shift 2 ;; --report) report="${2:-}"; shift 2 ;;
    --publish) publish="${2:-}"; shift 2 ;; --pr) pr="${2:-}"; shift 2 ;; --head-sha) head="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$launch" ] && [ -n "$report" ] && [ -n "$publish" ] || usage
[ -f "$report" ] || sdlc_die 2 "finalize.sh: report $report does not exist"
platform=$(sdlc_config .platform none)
rec=$(bash "$STATUS" get --launch "$launch" 2>/dev/null) || sdlc_die 2 "finalize.sh: unknown launch $launch"
[ -n "$head" ] || head=$(jq -r '.head_sha // ""' <<<"$rec")
[ -n "$pr" ] || pr=$(jq -r '.pr // ""' <<<"$rec")
branch=$(jq -r '.branch // ""' <<<"$rec")
if [ "$platform" = none ] || [ "$pr" = local ]; then pr=""; fi
[ -n "$head" ] || head=$(git -C "$SDLC_PROJECT_DIR" rev-parse HEAD 2>/dev/null || true)
[ -n "$head" ] || sdlc_die 2 "finalize.sh: no head sha (pass --head-sha)"
sha12="${head:0:12}"; lock_key="${pr:-local}"

fail() {  # fail <exit> <state> <detail>
  bash "$STATUS" set "$launch" "$2" "$3" >/dev/null 2>&1 || true
  echo "ai-sdlc: $3" >&2; exit "$1"
}

# 1. the report is a valid security report bound to the reviewed commit
if ! reason=$(bash "$SDLC_PLUGIN_ROOT/scripts/loop/validate-report.sh" "$report" --security --head "$head" 2>&1 >/dev/null); then
  reason="${reason#ai-sdlc: }"
  fail 1 "failed validate: $reason" "the assembled report failed validation: $reason (fix the report format and run finalize again; nothing was published)"
fi

if [ -n "$pr" ]; then
  # 2. the pull request head must still be the commit that was reviewed
  cur=$("$BIN" pr_get "$pr" 2>/dev/null | jq -r '.head_sha // ""' 2>/dev/null || true)
  [ -n "$cur" ] || fail 1 "failed post: pr_get" "sdlc-platform pr_get $pr did not return the head sha; the review cannot be bound to the pull request (nothing was published)"
  if [ "$cur" != "$head" ]; then
    tmp="$report.tmp.$$"
    awk -v note="**Status:** stale (the pull request head moved to ${cur:0:12} while this review of ${head:0:12} ran; superseded)" '
      { print } /^\*\*Commit:\*\*/ && !done { print note; done = 1 }' "$report" >"$tmp" && mv -f "$tmp" "$report"
    bash "$STATUS" unlock "$lock_key" "$sha12" >/dev/null 2>&1 || true
    fail 4 stale "the head of PR $pr moved to ${cur:0:12} while the review of $sha12 ran; the report is marked stale and not published (the next push launches a new review)"
  fi
  # 3. post the comment
  errf=$(sdlc_tmpfile .err)
  if ! posted=$("$BIN" pr_comment "$pr" "$report" 2>"$errf"); then
    first=$(head -n1 "$errf" 2>/dev/null); rm -f "$errf"
    fail 1 "failed post: ${first:-pr_comment failed}" "posting the review on PR $pr failed: ${first:-pr_comment exited non-zero} (the report stays at $report; retry finalize; nothing was published)"
  fi
  rm -f "$errf"
  comment_id=$(jq -r '.comment_id // ""' <<<"$posted" 2>/dev/null || true)
fi

# 4. publish atomically (same filesystem: both live under the artifacts directory)
mkdir -p "$(dirname "$publish")" || fail 1 "failed publish: mkdir" "cannot create $(dirname "$publish")"
mv -f "$report" "$publish" || fail 1 "failed publish: mv" "cannot move the report to $publish"
bash "$STATUS" attach "$launch" --report "$publish" >/dev/null 2>&1 || true
if [ -n "$pr" ]; then
  bash "$STATUS" set "$launch" posted "comment ${comment_id:-posted} on PR $pr; report $publish" >/dev/null 2>&1 || true
  [ -n "$branch" ] && bash "$STATUS" map --branch "$branch" --pr "$pr" --sha "$head" >/dev/null 2>&1
else
  bash "$STATUS" set "$launch" saved "report $publish (platform none: nothing to post)" >/dev/null 2>&1 || true
fi
bash "$STATUS" unlock "$lock_key" "$sha12" >/dev/null 2>&1 || true
jq -cn --arg r "$publish" --arg c "${comment_id:-}" --arg h "$head" --arg pr "$pr" \
  '{report:$r, comment_id:(if $c=="" then null else $c end), head_sha:$h, pr:(if $pr=="" then null else $pr end), state:(if $pr=="" then "saved" else "posted" end)}'
