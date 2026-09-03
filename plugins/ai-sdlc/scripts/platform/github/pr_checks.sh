#!/usr/bin/env bash
# pr_checks (GitHub): normalised check status. Exit 0 pass, 1 fail, 8 pending.
set -u
export SDLC_PLATFORM=github
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
id="${1:-}"; [[ "$id" =~ ^[0-9]+$ ]] || usage_die "pr_checks <id>"
require_gh
repo=$(gh_repo)
raw=$(cli gh pr checks "$id" --repo "$repo" --json name,state,link 2>/dev/null); rc=$?
[ -n "$raw" ] || { [ $rc -eq 0 ] && raw='[]' || sdlc_die 1 "gh pr checks $id failed (exit $rc)"; }
result=$(printf '%s' "$raw" | jq -c --arg id "$id" '
  def norm: ascii_upcase | if IN("SUCCESS","NEUTRAL","PASS","COMPLETED") then "pass"
    elif IN("FAILURE","ERROR","CANCELLED","TIMED_OUT","ACTION_REQUIRED","STARTUP_FAILURE","FAIL") then "fail"
    elif IN("SKIPPED","SKIPPING") then "skipped" else "pending" end;
  [.[] | {name, status: ((.state // .bucket // "pending")|norm), url: (.link // null)}] as $c
  | {id: $id, status: (if any($c[]; .status=="fail") then "fail" elif any($c[]; .status=="pending") then "pending" else "pass" end), checks: $c, platform: "github"}')
out_json "$result"
case "$(printf '%s' "$result" | jq -r .status)" in fail) exit 1 ;; pending) exit 8 ;; *) exit 0 ;; esac
