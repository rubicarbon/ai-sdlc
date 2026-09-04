#!/usr/bin/env bash
# Azure pr_get review_decision: votes, required approval count, required reviewers,
# author exclusion. Votes: 10 approved, 5 approved with suggestions, 0 none,
# -5 waiting for author, -10 rejected.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
BIN="$P/bin/sdlc-platform"
export SDLC_PLATFORM_MOCK=1 SDLC_MOCK_STATE="$EVAL_TMP/state"
mkdir -p "$SDLC_MOCK_STATE"

mkrepo() {  # mkrepo <dir> <requiredApprovals> <requiredReviewers-json>
  rm -rf "$1"; mkdir -p "$1"; git -C "$1" init -q -b main
  jq -cn --argjson n "$2" --argjson r "$3" '{version:1, platform:"azure", repo:{defaultBranch:"main"},
    review:{requiredApprovals:$n},
    azure:{organization:"https://dev.azure.com/mock-org", project:"mock-proj", repo:"mock-repo", requiredReviewers:$r}}' \
    >"$1/sdlc.config.json"
}
# decision <repo-dir> <reviewers-json> -> prints review_decision (or "exit N")
decision() {
  local out rc
  out=$(cd "$1" && SDLC_MOCK_PR_REVIEWERS="$2" "$BIN" --platform azure pr_get 5 2>"$EVAL_TMP/err" </dev/null); rc=$?
  if [ $rc -ne 0 ]; then echo "exit $rc: $(head -c 200 "$EVAL_TMP/err")"; else printf '%s' "$out" | jq -r .review_decision; fi
}
# The mock PR author is mock@example.com (id u-mock).
A='{"vote":10,"uniqueName":"a@example.com","displayName":"Alice","id":"r-a"}'
B='{"vote":10,"uniqueName":"b@example.com","displayName":"Bob","id":"r-b"}'
B0='{"vote":0,"uniqueName":"b@example.com","displayName":"Bob","id":"r-b"}'
LEAD='{"vote":10,"uniqueName":"lead@example.com","displayName":"Lead","id":"r-lead"}'
LEAD0='{"vote":0,"uniqueName":"lead@example.com","displayName":"Lead","id":"r-lead"}'

one="$EVAL_TMP/one"; mkrepo "$one" 1 '[]'
two="$EVAL_TMP/two"; mkrepo "$two" 2 '[]'
req2="$EVAL_TMP/req2"; mkrepo "$req2" 1 '["a@example.com","b@example.com"]'
lead="$EVAL_TMP/lead"; mkrepo "$lead" 1 '["Lead@Example.com"]'

assert_eq "pending" "$(decision "$two" "[$A]")" "insufficient count: requiredApprovals 2 with one approval is pending"
assert_eq "approved" "$(decision "$two" "[$A,$B]")" "two approvals satisfy requiredApprovals 2"
assert_eq "pending" "$(decision "$req2" "[$A,$B0]")" "partial approval: one of two required reviewers is pending"
assert_eq "approved" "$(decision "$req2" "[$A,$B]")" "both required reviewers approved"
assert_eq "pending" "$(decision "$lead" "[$A,$LEAD0]")" "required reviewer missing: approval by a non-required reviewer is pending"
assert_eq "approved" "$(decision "$lead" "[$LEAD]")" "required reviewer matched case-insensitively -> approved"
assert_eq "approved" "$(decision "$lead" '[{"vote":5,"uniqueName":"x@example.com","displayName":"lead@example.com"}]')" "required reviewer matched on displayName; vote 5 counts as approval"
assert_eq "changes_requested" "$(decision "$one" "[$A,{\"vote\":-10,\"uniqueName\":\"c@example.com\"}]")" "rejection (-10) wins over other approvals"
assert_eq "changes_requested" "$(decision "$one" "[$A,{\"vote\":-5,\"uniqueName\":\"c@example.com\"}]")" "waiting for author (-5) is changes_requested"
assert_eq "pending" "$(decision "$one" '[{"vote":10,"uniqueName":"MOCK@example.com","displayName":"Mock User","id":"u-mock"}]')" "author self-approval (uniqueName) does not count"
assert_eq "pending" "$(decision "$one" '[{"vote":10,"uniqueName":"other-alias@example.com","id":"u-mock"}]')" "author self-approval (id) does not count"
assert_eq "pending" "$(decision "$one" '[{"vote":10,"uniqueName":"[mock-proj]\\Reviewers","isContainer":true}]')" "a group (isContainer) vote does not count towards the approval count"
assert_eq "pending" "$(decision "$one" "[$A,{\"vote\":0,\"uniqueName\":\"sec@example.com\",\"isRequired\":true}]")" "a reviewer flagged isRequired who has not voted keeps the PR pending"
assert_eq "approved" "$(decision "$one" "[$A,{\"vote\":5,\"uniqueName\":\"sec@example.com\",\"isRequired\":true}]")" "isRequired reviewer approved with suggestions -> approved"
assert_eq "pending" "$(decision "$one" '[]')" "no reviewers is pending"
assert_eq "approved" "$(decision "$one" "[$A]")" "full approval -> approved"

echo "-- default mock reviewers and key set unchanged"
out=$(cd "$one" && "$BIN" --platform azure pr_get 5 2>/dev/null)
assert_eq "pending" "$(printf '%s' "$out" | jq -r .review_decision)" "default mock reviewer (vote 0) is pending"
assert_eq '["additions","author","base","changed_files","closed_at","created_at","deletions","head","id","merged_at","platform","review_decision","state","title","url"]' \
  "$(printf '%s' "$out" | jq -c 'keys')" "pr_get key set unchanged"
eval_done
