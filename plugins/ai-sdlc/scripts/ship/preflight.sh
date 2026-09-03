#!/usr/bin/env bash
# preflight.sh — every gate a release must pass, as one JSON verdict for /sdlc-ship.
#   preflight.sh [--pr <id>] [--platform github|azure]
# Exit 0 when every gate is green, 1 otherwise (the JSON lists each gate and its evidence).
set -u
. "${0%/*}/../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"
. "$SDLC_PLUGIN_ROOT/scripts/_project.sh"
pr=""; pargs=()
while [ $# -gt 0 ]; do case "$1" in --pr) pr="$2"; shift 2 ;; --platform) pargs=(--platform "$2"); shift 2 ;; *) sdlc_die 2 "preflight.sh [--pr <id>] [--platform github|azure]" ;; esac; done
art=$(sdlc_artifacts_dir); BIN="$SDLC_PLUGIN_ROOT/bin/sdlc-platform"
gates='[]'
gate() { gates=$(jq -c --arg n "$1" --argjson ok "$2" --arg e "$3" '. + [{gate:$n,ok:$ok,evidence:$e}]' <<<"$gates"); }

msg=$(bash "$SDLC_PLUGIN_ROOT/scripts/loop/precondition.sh" ship 2>/dev/null); rc=$?
latest=$(ls -t "$art"/verify/*.md 2>/dev/null | grep -v -- '-security.md' | head -n1 || true)
gate "verification report PASS" "$([ $rc -eq 0 ] && echo true || echo false)" "${latest:-$msg}"
sec=$(ls -t "$art"/verify/*-security.md 2>/dev/null | head -n1 || true)
if [ -n "$sec" ]; then blocking=$(grep -m1 -oE 'Blocking: [0-9]+' "$sec" | grep -oE '[0-9]+' || echo 0); gate "security review without Blocking findings" "$([ "${blocking:-0}" -eq 0 ] && echo true || echo false)" "$sec (Blocking: ${blocking:-?})"; else gate "security review present" false "no $art/verify/*-security.md: run /ai-sdlc:sdlc-verify --security"; fi
head_sha=$(git -C "$SDLC_PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
gate "working tree clean" "$([ -z "$(git -C "$SDLC_PROJECT_DIR" status --porcelain 2>/dev/null)" ] && echo true || echo false)" "git status --porcelain"
platform=$(sdlc_config .platform none)
if [ -n "$pr" ] && [ "$platform" != none ]; then
  prj=$("$BIN" "${pargs[@]+"${pargs[@]}"}" pr_get "$pr" 2>/dev/null || echo '{}')
  gate "human approval on PR $pr" "$([ "$(jq -r '.review_decision // "pending"' <<<"$prj")" = approved ] && echo true || echo false)" "review_decision=$(jq -r '.review_decision // "unknown"' <<<"$prj")"
  chk=$("$BIN" "${pargs[@]+"${pargs[@]}"}" pr_checks "$pr" 2>/dev/null); crc=$?
  gate "checks pass on PR $pr" "$([ $crc -eq 0 ] && echo true || echo false)" "status=$(jq -r '.status // "unknown"' <<<"${chk:-{\}}") (exit $crc)"
else
  gate "pull request named" false "pass --pr <id> so approval and checks can be verified"
fi
authf="$art/release/AUTHORIZED-$head_sha"
if [ -f "$authf" ]; then exp=$(sed -n 's/^expires=//p' "$authf"); now=$(date +%s); gate "release authorised for HEAD" "$([ -n "$exp" ] && [ "$now" -le "$exp" ] && echo true || echo false)" "$authf expires=$exp"; else gate "release authorised for HEAD" false "no $art/release/AUTHORIZED-${head_sha:0:12}: a human runs scripts/ship/authorize.sh"; fi
all=$(jq 'all(.[]; .ok)' <<<"$gates")
jq -cn --argjson g "$gates" --argjson ok "$all" --arg sha "$head_sha" '{head:$sha, ready:$ok, gates:$g}'
[ "$all" = true ]
