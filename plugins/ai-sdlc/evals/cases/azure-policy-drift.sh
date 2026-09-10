#!/usr/bin/env bash
# Azure branch_protect_apply compares managed settings, creates what is missing, updates
# what drifted, leaves equal policies alone and never touches policies of other types,
# branches or repositories.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
BIN="$P/bin/sdlc-platform"
export SDLC_PLATFORM_MOCK=1 SDLC_MOCK_STATE="$EVAL_TMP/state" SDLC_CI_TEMPLATES_DIR="$P/scripts/platform/_mocks/templates"
mkdir -p "$SDLC_MOCK_STATE"
POL="$SDLC_MOCK_STATE/policies.json"
repo="$EVAL_TMP/repo"; rm -rf "$repo"; mkdir -p "$repo"; git -C "$repo" init -q -b main
write_config() {  # write_config <requiredApprovals>
  jq -cn --argjson n "$1" '{version:1, platform:"azure", repo:{defaultBranch:"main"}, review:{requiredApprovals:$n},
    azure:{organization:"https://dev.azure.com/mock-org", project:"mock-proj", repo:"mock-repo",
           requiredReviewers:["lead@example.com"], pipelineName:"sdlc-mock"}}' >"$repo/sdlc.config.json"
}
apply() { OUT=$(cd "$repo" && "$BIN" --platform azure branch_protect_apply main 2>"$EVAL_TMP/err" </dev/null); RC=$?; ERR=$(<"$EVAL_TMP/err"); }
field() { printf '%s' "$OUT" | jq -c "$1"; }
stored() { jq -c "$1" "$POL"; }   # stored <jq> over the mock's policy store

write_config 1
# register the build pipeline so the build policy can be created too
( cd "$repo" && "$BIN" --platform azure ci_workflow_install >/dev/null 2>&1 )

echo "-- pre-seeded policies that must never be touched"
jq -cn '[
  {id:900, isEnabled:true, isBlocking:false, type:{id:"fa4e907d-c16b-4a4c-9dfa-4906e5d171de", displayName:"Require a merge strategy"},
   settings:{useSquashMerge:true, scope:[{refName:"refs/heads/main", matchKind:"Exact", repositoryId:"11111111-2222-3333-4444-555555555555"}]}},
  {id:901, isEnabled:true, isBlocking:true, type:{id:"fa4e907d-c16b-4a4c-9dfa-4906e5d171dd", displayName:"Minimum number of reviewers"},
   settings:{minimumApproverCount:7, creatorVoteCounts:true, allowDownvotes:true, resetOnSourcePush:false,
             scope:[{refName:"refs/heads/other", matchKind:"Exact", repositoryId:"11111111-2222-3333-4444-555555555555"}]}},
  {id:902, isEnabled:true, isBlocking:true, type:{id:"fa4e907d-c16b-4a4c-9dfa-4906e5d171dd", displayName:"Minimum number of reviewers"},
   settings:{minimumApproverCount:3, creatorVoteCounts:false, allowDownvotes:false, resetOnSourcePush:true,
             scope:[{refName:"refs/heads/main", matchKind:"Exact", repositoryId:"99999999-0000-0000-0000-000000000000"}]}}
]' >"$POL"
seeded=$(stored 'map(select(.id >= 900))')

echo "-- first apply creates every policy"
apply
assert_eq "0" "$RC" "first apply exits 0 ($ERR)"
assert_eq '["approver-count","required-reviewer","work-item-linking","comment-required","build"]' "$(field .applied)" "first apply creates all five policies"
assert_eq "[]" "$(field .updated)" "first apply updates nothing"
assert_eq "[]" "$(field .unchanged)" "first apply has nothing unchanged"
assert_eq "[]" "$(field .skipped)" "first apply skips nothing (pipeline registered, reviewers configured)"
assert_eq "1" "$(stored '[.[] | select(.type.displayName=="Minimum number of reviewers" and .settings.scope[0].refName=="refs/heads/main" and .settings.scope[0].repositoryId=="11111111-2222-3333-4444-555555555555")] | .[0].settings.minimumApproverCount')" "stored minimumApproverCount is 1"
assert_eq '["lead@example.com"]' "$(stored '[.[] | select(.type.displayName=="Required reviewers")] | .[0].settings.requiredReviewerIds')" "required reviewer ids stored"
assert_eq "720" "$(stored '[.[] | select(.type.displayName=="Build")] | .[0].settings.validDuration')" "build validDuration stored"

echo "-- second apply is idempotent"
apply
assert_eq "0" "$RC" "second apply exits 0"
assert_eq "[]" "$(field .applied)" "second apply creates nothing"
assert_eq "[]" "$(field .updated)" "second apply updates nothing"
assert_eq "5" "$(field '.unchanged|length')" "second apply reports all five unchanged"
assert_eq "8" "$(stored 'length')" "no duplicate policies were created"

echo "-- config drift: requiredApprovals 1 -> 2 updates the approver-count policy in place"
write_config 2
apply
assert_eq "0" "$RC" "drift apply exits 0"
assert_eq '["approver-count"]' "$(field .updated)" "only approver-count is updated"
assert_eq "[]" "$(field .applied)" "drift creates nothing"
assert_eq "4" "$(field '.unchanged|length')" "the other four are unchanged"
main_ac='[.[] | select(.type.displayName=="Minimum number of reviewers" and .settings.scope[0].refName=="refs/heads/main" and .settings.scope[0].repositoryId=="11111111-2222-3333-4444-555555555555")]'
assert_eq "1" "$(stored "$main_ac | length")" "still exactly one approver-count policy for main in this repo"
assert_eq "2" "$(stored "$main_ac | .[0].settings.minimumApproverCount")" "stored minimumApproverCount is now 2"
assert_eq "8" "$(stored 'length')" "update did not add a policy"

echo "-- enabled/blocking drift is detected"
jq -c 'map(if (.type.displayName=="Comment requirements" and .settings.scope[0].refName=="refs/heads/main") then .isBlocking=false else . end)' "$POL" >"$POL.tmp" && mv "$POL.tmp" "$POL"
apply
assert_eq '["comment-required"]' "$(field .updated)" "isBlocking false on the comment policy -> updated"
assert_eq "true" "$(stored '[.[] | select(.type.displayName=="Comment requirements")] | .[0].isBlocking')" "isBlocking restored to true"
jq -c 'map(if (.type.displayName=="Build") then .isEnabled=false | .settings.validDuration=10 else . end)' "$POL" >"$POL.tmp" && mv "$POL.tmp" "$POL"
apply
assert_eq '["build"]' "$(field .updated)" "disabled build policy with a different validDuration -> updated"
assert_eq "true 720" "$(stored '[.[] | select(.type.displayName=="Build")] | .[0] | "\(.isEnabled) \(.settings.validDuration)"' | tr -d '"')" "build policy re-enabled with validDuration 720"

echo "-- required reviewer set compared as a set"
jq -c 'map(if (.type.displayName=="Required reviewers") then .settings.requiredReviewerIds=["LEAD@example.com"] else . end)' "$POL" >"$POL.tmp" && mv "$POL.tmp" "$POL"
apply
assert_eq "[]" "$(field .updated)" "case-only difference in reviewer ids is not drift"
jq -c 'map(if (.type.displayName=="Required reviewers") then .settings.requiredReviewerIds=["someone-else@example.com"] else . end)' "$POL" >"$POL.tmp" && mv "$POL.tmp" "$POL"
apply
assert_eq '["required-reviewer"]' "$(field .updated)" "a different reviewer set is drift"

echo "-- unrelated policies are untouched after every apply"
assert_eq "$seeded" "$(stored 'map(select(.id >= 900))')" "other type, other branch and other repository policies are byte-identical"
assert_eq "0" "$(grep -c 'update --id 90[0-9]' "$EVAL_TMP/err" 2>/dev/null || true)" "no update was issued against a seeded policy"

echo "-- an API failure is an error, never an empty policy list"
before=$(stored 'length')
OUT=$(cd "$repo" && SDLC_MOCK_FAIL="repos policy list" "$BIN" --platform azure branch_protect_apply main 2>"$EVAL_TMP/err" </dev/null); RC=$?
assert_eq "1" "$RC" "policy list failure exits 1"
assert_match 'ai-sdlc: az repos policy list --branch main failed \(exit 1\)' "$(cat "$EVAL_TMP/err")" "failure names the command"
assert_eq "$before" "$(stored 'length')" "nothing was created after the failed list"

echo "-- dry-run prints the az commands and changes no policy"
snapshot=$(cat "$POL")
OUT=$(cd "$repo" && "$BIN" --platform azure --dry-run branch_protect_apply main 2>/dev/null </dev/null); RC=$?
assert_eq "0" "$RC" "dry-run exits 0"
assert_match '^\+ az ' "$OUT" "dry-run prints the commands"
assert_eq "$snapshot" "$(cat "$POL")" "dry-run wrote no policy (mock state unchanged)"

echo "-- review.runner local removes the retired sdlc-pr-review build policy and keeps a custom one"
jq -cn '{version:1, platform:"azure", repo:{defaultBranch:"main"}, review:{requiredApprovals:2, runner:"local"},
  azure:{organization:"https://dev.azure.com/mock-org", project:"mock-proj", repo:"mock-repo", requiredReviewers:["lead@example.com"], pipelineName:"sdlc-mock"}}' >"$repo/sdlc.config.json"
printf '{"review-runner":{"from":"ci","to":"local","at":"2026-09-10T00:00:00Z","remote":"pending"}}\n' >"$repo/.sdlc/migrations.json" 2>/dev/null || { mkdir -p "$repo/.sdlc"; printf '{"review-runner":{"from":"ci","to":"local","at":"2026-09-10T00:00:00Z","remote":"pending"}}\n' >"$repo/.sdlc/migrations.json"; }
# an obsolete review build policy on main, plus one on another branch that must stay
jq -c '. + [
  {id:950, isEnabled:true, isBlocking:true, type:{id:"0609b952-1397-4640-95ec-e00a01b2c241", displayName:"Build"},
   settings:{buildDefinitionId:"77", displayName:"sdlc-pr-review", queueOnSourceUpdateOnly:true, manualQueueOnly:false, validDuration:720,
             scope:[{refName:"refs/heads/main", matchKind:"Exact", repositoryId:"11111111-2222-3333-4444-555555555555"}]}},
  {id:951, isEnabled:true, isBlocking:true, type:{id:"0609b952-1397-4640-95ec-e00a01b2c241", displayName:"Build"},
   settings:{buildDefinitionId:"78", displayName:"sdlc-pr-review", queueOnSourceUpdateOnly:true, manualQueueOnly:false, validDuration:720,
             scope:[{refName:"refs/heads/other", matchKind:"Exact", repositoryId:"11111111-2222-3333-4444-555555555555"}]}}]' "$POL" >"$POL.tmp" && mv "$POL.tmp" "$POL"
seed950=$(jq -c '.[] | select(.id == 950)' "$POL")
OUT=$(cd "$repo" && "$BIN" --platform azure --dry-run branch_protect_apply main 2>/dev/null </dev/null); RC=$?
assert_match '\+ az repos policy delete --id 950 --yes' "$OUT" "dry-run prints the delete of the retired review policy"
assert_eq "pending" "$(jq -r '.["review-runner"].remote' "$repo/.sdlc/migrations.json")" "dry-run leaves the migration pending"
# the mocks mutate their store under dry-run too; put the retired policy back for the real apply
jq -c --argjson p "$seed950" 'map(select(.id != 950)) + [$p]' "$POL" >"$POL.tmp" && mv "$POL.tmp" "$POL"
apply
assert_eq "0" "$RC" "local apply exits 0 ($ERR)"
assert_eq '["build: sdlc-pr-review (policy 950)"]' "$(field .removed)" "the retired review build policy on main is removed"
assert_eq "1" "$(stored '[.[] | select(.id == 951)] | length')" "the sdlc-pr-review build policy on another branch is untouched"
assert_eq "1" "$(stored '[.[] | select(.type.displayName=="Build" and .settings.displayName=="sdlc-mock")] | length')" "the custom build policy (sdlc-mock) is kept"
assert_eq '"unchanged"' "$(field '.unchanged | index("build") | if . == null then "absent" else "unchanged" end')" "the custom build policy is reported unchanged"
assert_eq "done" "$(jq -r '.["review-runner"].remote' "$repo/.sdlc/migrations.json")" "a real apply marks the review-runner migration reconciled"
apply
assert_eq "[]" "$(field .removed)" "second local apply removes nothing more"
echo "-- review.runner local without a custom pipeline: no build policy at all"
jq -c 'del(.azure.pipelineName)' "$repo/sdlc.config.json" >"$repo/c.json" && mv "$repo/c.json" "$repo/sdlc.config.json"
apply
assert_eq "0" "$RC" "local apply without pipelineName exits 0 ($ERR)"
assert_eq "4" "$(field '.unchanged|length')" "four policies managed, no build policy"
assert_not_match 'build' "$(field '.applied + .updated + .unchanged | join(",")')" "no build policy is created without a build requirement"
echo "-- review.runner ci removes nothing"
jq -c '.review.runner="ci" | .azure.pipelineName="sdlc-mock"' "$repo/sdlc.config.json" >"$repo/c.json" && mv "$repo/c.json" "$repo/sdlc.config.json"
jq -c '. + [{id:952, isEnabled:true, isBlocking:true, type:{id:"0609b952-1397-4640-95ec-e00a01b2c241", displayName:"Build"},
   settings:{buildDefinitionId:"79", displayName:"sdlc-pr-review", queueOnSourceUpdateOnly:true, manualQueueOnly:false, validDuration:720,
             scope:[{refName:"refs/heads/main", matchKind:"Exact", repositoryId:"11111111-2222-3333-4444-555555555555"}]}}]' "$POL" >"$POL.tmp" && mv "$POL.tmp" "$POL"
apply
assert_eq "[]" "$(field .removed)" "runner ci never removes a build policy"
assert_eq "1" "$(stored '[.[] | select(.id == 952)] | length')" "the sdlc-pr-review policy stays under runner ci"

eval_done
