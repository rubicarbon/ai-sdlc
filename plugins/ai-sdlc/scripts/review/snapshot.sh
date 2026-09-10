#!/usr/bin/env bash
# snapshot.sh — the exact pull-request head in a disposable worktree, for /ai-sdlc:sdlc-review.
#
#   snapshot.sh --launch <id> --pr <id> --head-sha <sha> --base-sha <sha> \
#               --head-repo-url <url> --head-ref <branch>
#   snapshot.sh --launch <id> --local [--base <ref>]          platform none: review local HEAD
#   snapshot.sh --cleanup --launch <id>
#
# The reviewer never reads the author's checkout. The head commit is fetched (GitHub:
# refs/pull/<id>/head from origin first, which also covers forks; then <head-repo-url> <head-ref>),
# and the fetched commit must be exactly --head-sha, the commit the platform reported through
# sdlc-platform pr_get; otherwise exit 3 ("head moved": review again once the push settled). The
# base commit is fetched when missing. A detached worktree of head_sha is created under
# <artifacts>/tmp/review/wt-<launch>/ (or $SDLC_TMPDIR) and reported as JSON:
#   {"dir","head_sha","base_sha","pr","launch"}
# One review per pull request and head at a time: the launch takes the lock
# lock-<pr>-<sha12> through status.sh; when another live launch holds it this launch is marked
# "skipped duplicate" and exits 5. Exit 2 is a usage or environment error.
# --local (platform none, no pull request): head_sha is HEAD, base_sha the merge base with --base
# (default repo.defaultBranch), the lock key is "local".
set -u
. "${0%/*}/../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"
. "$SDLC_PLUGIN_ROOT/scripts/_project.sh"
[ -n "${SDLC_PROJECT_DIR:-}" ] || sdlc_die 2 "snapshot.sh: no sdlc.config.json found (not an sdlc project)"
STATUS="$SDLC_PLUGIN_ROOT/scripts/review/status.sh"
usage() { sdlc_die 2 "snapshot.sh --launch <id> (--pr <id> --head-sha <sha> --base-sha <sha> --head-repo-url <url> --head-ref <branch> | --local [--base <ref>] | --cleanup)"; }

launch=""; pr=""; head_sha=""; base_sha=""; url=""; ref=""; local_mode=0; base_ref=""; cleanup=0
while [ $# -gt 0 ]; do
  case "$1" in
    --launch) launch="${2:-}"; shift 2 ;; --pr) pr="${2:-}"; shift 2 ;;
    --head-sha) head_sha="${2:-}"; shift 2 ;; --base-sha) base_sha="${2:-}"; shift 2 ;;
    --head-repo-url) url="${2:-}"; shift 2 ;; --head-ref) ref="${2:-}"; shift 2 ;;
    --local) local_mode=1; shift ;; --base) base_ref="${2:-}"; shift 2 ;;
    --cleanup) cleanup=1; shift ;;
    *) usage ;;
  esac
done
[ -n "$launch" ] || usage
main="$SDLC_PROJECT_DIR"; art=$(sdlc_artifacts_dir)
base_dir="${SDLC_TMPDIR:-$art/tmp/review}"
wt="$base_dir/wt-$launch"

if [ $cleanup = 1 ]; then
  git -C "$main" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
  git -C "$main" worktree prune >/dev/null 2>&1 || true
  rec=$(bash "$STATUS" get --launch "$launch" 2>/dev/null || true)
  if [ -n "$rec" ]; then
    lp=$(jq -r '.pr // "local"' <<<"$rec"); ls=$(jq -r '.head_sha // ""' <<<"$rec")
    [ -n "$ls" ] && bash "$STATUS" unlock "$lp" "${ls:0:12}" >/dev/null 2>&1
  fi
  exit 0
fi

platform=$(sdlc_config .platform none)
if [ $local_mode = 1 ]; then
  [ -n "$base_ref" ] || base_ref=$(sdlc_config .repo.defaultBranch main)
  head_sha=$(git -C "$main" rev-parse --verify HEAD 2>/dev/null) || sdlc_die 2 "snapshot.sh: nothing committed yet"
  base_sha=$(git -C "$main" merge-base HEAD "$base_ref" 2>/dev/null) || sdlc_die 2 "snapshot.sh: cannot find the merge base of HEAD and $base_ref"
  pr=local
else
  [ -n "$pr" ] && [ -n "$head_sha" ] && [ -n "$base_sha" ] || usage
  [[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] || sdlc_die 2 "snapshot.sh: --head-sha must be a full 40-hex sha (got '$head_sha')"
fi
sha12="${head_sha:0:12}"

# one live review per pull request and head
if ! holder=$(bash "$STATUS" lock "$pr" "$sha12" "$launch"); then
  bash "$STATUS" set "$launch" "skipped duplicate" "launch $holder is already reviewing PR $pr at $sha12" >/dev/null 2>&1 || true
  echo "ai-sdlc: another review of PR $pr at $sha12 is in progress (launch $holder); this launch is skipped" >&2
  exit 5
fi
fail() {  # fail <exit> <state> <detail>
  bash "$STATUS" set "$launch" "$2" "$3" >/dev/null 2>&1 || true
  bash "$STATUS" unlock "$pr" "$sha12" >/dev/null 2>&1 || true
  echo "ai-sdlc: $3" >&2; exit "$1"
}

if [ $local_mode = 0 ]; then
  # fetch the head: GitHub exposes refs/pull/<id>/head on origin (forks included); otherwise the
  # head repository and branch the adapter reported
  fetched=0
  if [ "$platform" = github ] && git -C "$main" fetch --quiet origin "+refs/pull/$pr/head" >/dev/null 2>&1; then fetched=1
  elif [ -n "$url" ] && [ -n "$ref" ] && git -C "$main" fetch --quiet "$url" "$ref" >/dev/null 2>&1; then fetched=1
  fi
  [ $fetched = 1 ] || fail 2 "failed fetch" "could not fetch the head of PR $pr (refs/pull/$pr/head on origin, or $ref from $url); the review must start from the commit the platform reports"
  got=$(git -C "$main" rev-parse --verify FETCH_HEAD 2>/dev/null || true)
  [ "$got" = "$head_sha" ] || fail 3 "failed head-moved" "the fetched head of PR $pr is ${got:0:12}, not the reported $sha12: the pull request moved while the review was starting; review again once the push settled"
  if ! git -C "$main" cat-file -e "$base_sha^{commit}" 2>/dev/null; then
    git -C "$main" fetch --quiet origin "$base_sha" >/dev/null 2>&1 || git -C "$main" fetch --quiet origin >/dev/null 2>&1 || true
    git -C "$main" cat-file -e "$base_sha^{commit}" 2>/dev/null || fail 2 "failed fetch" "the base commit ${base_sha:0:12} of PR $pr is not available locally after fetching origin"
  fi
fi

mkdir -p "$base_dir" || fail 2 "failed worktree" "cannot create $base_dir"
git -C "$main" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
errf=$(sdlc_tmpfile .err)
if ! git -C "$main" worktree add --detach "$wt" "$head_sha" >/dev/null 2>"$errf"; then
  reason=$(head -n1 "$errf"); rm -f "$errf"
  fail 2 "failed worktree" "git worktree add failed: $reason"
fi
rm -f "$errf"
bash "$STATUS" attach "$launch" --pr "$pr" --head-sha "$head_sha" --base-sha "$base_sha" >/dev/null 2>&1 || true
jq -cn --arg d "$wt" --arg h "$head_sha" --arg b "$base_sha" --arg pr "$pr" --arg l "$launch" \
  '{dir:$d, head_sha:$h, base_sha:$b, pr:$pr, launch:$l}'
