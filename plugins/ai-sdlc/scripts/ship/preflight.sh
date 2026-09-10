#!/usr/bin/env bash
# preflight.sh — every gate a release must pass, as one JSON verdict for /sdlc-ship.
#   preflight.sh [--pr <id>] [--platform github|azure]
# Exit 0 when every gate is green, 1 otherwise (the JSON lists each gate and its evidence).
# Read-only: it never writes to the project. The report rules live in scripts/loop/_reports.sh
# and the authorisation rules in scripts/ship/_authz.sh, shared with precondition.sh and the
# production gate hook, so the three always agree.
set -u
. "${0%/*}/../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"
. "$SDLC_PLUGIN_ROOT/scripts/_project.sh"
. "$SDLC_PLUGIN_ROOT/scripts/loop/_reports.sh"
. "$SDLC_PLUGIN_ROOT/scripts/ship/_authz.sh"
pr=""; pargs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) pr="$2"; shift 2 ;;
    --platform) pargs=(--platform "$2"); shift 2 ;;
    *) sdlc_die 2 "preflight.sh [--pr <id>] [--platform github|azure]" ;;
  esac
done
art=$(sdlc_artifacts_dir); BIN="$SDLC_PLUGIN_ROOT/bin/sdlc-platform"
gates='[]'
gate() {  # gate <name> <true|false> <evidence>
  gates=$(jq -c --arg n "$1" --argjson ok "$2" --arg e "$3" '. + [{gate:$n,ok:$ok,evidence:$e}]' <<<"$gates")
}
bool() { if "$@"; then echo true; else echo false; fi; }

head_sha=$(git -C "$SDLC_PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)

# 1. verification report: the newest report bound to HEAD is a valid PASS
if report=$(sdlc_select_verify_report "$art/verify" "$head_sha"); then
  gate "verification report PASS" true "$report (Verdict PASS, Commit bound to HEAD ${head_sha:0:12})"
else
  gate "verification report PASS" false "$report"
fi

# 2. security report: the report sdlc_select_security_report picks for this runner, platform
#    and PR (review.runner ci: newest *-security.md; local: only the PR-bound report, Commit
#    required, no fallback) parses and has Blocking 0. Called without a subshell so the side
#    channel (count, reason, warning) survives.
runner=$(sdlc_config .review.runner ci); platform=$(sdlc_config .platform none)
self=$(sdlc_tmpfile)
if sdlc_select_security_report "$art/verify" "$head_sha" --runner "$runner" --platform "$platform" ${pr:+--pr "$pr"} >"$self" 2>/dev/null; then
  sec=$(<"$self"); blocking="$SDLC_REPORT_BLOCKING"
  gate "security review without Blocking findings" "$(bool [ "$blocking" -eq 0 ])" \
    "$sec (Blocking: $blocking)${SDLC_REPORT_WARNING:+; $SDLC_REPORT_WARNING}"
elif [ "$SDLC_REPORT_CODE" = no-file ] || [ "$SDLC_REPORT_CODE" = no-pr ]; then
  gate "security review present" false "$SDLC_REPORT_REASON"
else
  gate "security review without Blocking findings" false "$SDLC_REPORT_REASON"
fi
rm -f "$self"

# 3. working tree
gate "working tree clean" "$(bool [ -z "$(git -C "$SDLC_PROJECT_DIR" status --porcelain 2>/dev/null)" ])" \
  "git status --porcelain"

# 4. pull request: approval and checks through the platform adapter
platform=$(sdlc_config .platform none)
if [ -n "$pr" ] && [ "$platform" != none ]; then
  prj=$("$BIN" "${pargs[@]+"${pargs[@]}"}" pr_get "$pr" 2>/dev/null || echo '{}')
  decision=$(jq -r '.review_decision // "unknown"' <<<"$prj")
  gate "human approval on PR $pr" "$(bool [ "$decision" = approved ])" "review_decision=$decision"
  chk=$("$BIN" "${pargs[@]+"${pargs[@]}"}" pr_checks "$pr" 2>/dev/null); crc=$?
  [ -n "$chk" ] || chk='{}'
  status=$(jq -r '.status // "unknown"' <<<"$chk" 2>/dev/null || echo unknown)
  reason=$(jq -r '.reason // empty' <<<"$chk" 2>/dev/null || true)
  gate "checks pass on PR $pr" "$(bool [ $crc -eq 0 ])" "status=$status (exit $crc)${reason:+: $reason}"
else
  gate "pull request named" false "pass --pr <id> so approval and checks can be verified"
fi

# 5. release authorisation for HEAD (a human wrote it; the hook checks the same rules)
authf="$art/release/AUTHORIZED-$head_sha"
if reason=$(sdlc_check_authorization "$authf" "$head_sha"); then
  gate "release authorised for HEAD" true "$authf (all fields valid, not expired)"
else
  gate "release authorised for HEAD" false "$reason: a human runs scripts/ship/authorize.sh"
fi

all=$(jq 'all(.[]; .ok)' <<<"$gates")
jq -cn --argjson g "$gates" --argjson ok "$all" --arg sha "$head_sha" '{head:$sha, ready:$ok, gates:$g}'
[ "$all" = true ]
