#!/usr/bin/env bash
# pr_checks (GitHub): normalised check status. Exit 0 pass, 1 fail, 8 pending.
# The verdict rules live in _common.sh (pr_checks_result) and are shared with Azure:
# the function never passes with zero checks, and every name in github.requiredChecks
# must be present with status pass.
set -u
export SDLC_PLATFORM=github
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
id="${1:-}"; [[ "$id" =~ ^[0-9]+$ ]] || usage_die "pr_checks <id>"
require_gh
repo=$(gh_repo)
required=$(config_array '.github.requiredChecks')

# gh exits 1 when a check failed and 8 while checks are pending, printing the JSON in both
# cases; it prints nothing and exits 1 when the branch has no checks at all.
errf=$(sdlc_tmpfile .err)
raw=$(cli gh pr checks "$id" --repo "$repo" --json name,state,link 2>"$errf"); rc=$?
first=$(head -n1 "$errf" 2>/dev/null); rm -f "$errf"
if [ -z "$raw" ]; then
  if [ $rc -eq 0 ] || [[ "$first" =~ no\ checks\ reported ]]; then raw='[]'
  else sdlc_die 1 "gh pr checks $id failed (exit $rc): ${first:-no error output}"; fi
fi
printf '%s' "$raw" | jq -e 'type=="array"' >/dev/null 2>&1 \
  || sdlc_die 1 "gh pr checks $id returned invalid JSON: ${raw:0:120}"

checks=$(printf '%s' "$raw" | jq -c '
  def norm: ascii_upcase | if IN("SUCCESS","NEUTRAL","PASS","COMPLETED") then "pass"
    elif IN("FAILURE","ERROR","CANCELLED","TIMED_OUT","ACTION_REQUIRED","STARTUP_FAILURE","FAIL") then "fail"
    elif IN("SKIPPED","SKIPPING") then "skipped" else "pending" end;
  [.[] | {name, status: ((.state // .bucket // "pending")|norm), url: (.link // null)}]')
result=$(pr_checks_result "$id" github "$checks" "$required")
out_json "$result"
pr_checks_exit "$result"
