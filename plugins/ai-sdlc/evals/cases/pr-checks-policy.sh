#!/usr/bin/env bash
# pr_checks never passes with zero checks and enforces the configured required checks,
# with the same verdicts, reasons and exit codes on GitHub and Azure DevOps.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
BIN="$P/bin/sdlc-platform"
export SDLC_PLATFORM_MOCK=1 SDLC_MOCK_STATE="$EVAL_TMP/state"
mkdir -p "$SDLC_MOCK_STATE"

mkrepo() {  # mkrepo <dir> <config-json>
  rm -rf "$1"; mkdir -p "$1"; git -C "$1" init -q -b main
  printf '%s\n' "$2" >"$1/sdlc.config.json"
}
# run <platform> <repo-dir> -> OUT, RC, ERR
run() {
  local p="$1" d="$2"; shift 2
  local errf="$EVAL_TMP/err.$$"
  OUT=$(cd "$d" && "$BIN" --platform "$p" pr_checks 7 2>"$errf" </dev/null); RC=$?; ERR=$(<"$errf"); rm -f "$errf"
}
field() { printf '%s' "$OUT" | jq -r "$1"; }

echo "-- github: required check absent from an otherwise passing list"
gh="$EVAL_TMP/gh"
mkrepo "$gh" '{"version":1,"platform":"github","repo":{"owner":"mock-org","name":"mock-repo"},"github":{"requiredChecks":["ci","lint","missing-check"]}}'
SDLC_MOCK_CHECKS=pass run github "$gh"
assert_eq "1" "$RC" "github: missing required check exits 1"
assert_eq "fail" "$(field .status)" "github: status is fail"
assert_match 'required checks missing or skipped: missing-check' "$(field .reason)" "github: reason names the missing check"
assert_eq '["ci","lint","missing-check"]' "$(printf '%s' "$OUT" | jq -c .required)" "github: required names come from github.requiredChecks"
assert_eq "2" "$(field '.checks|length')" "github: the checks list is still reported"

echo "-- github: a failing check wins over a missing required one"
SDLC_MOCK_CHECKS=fail run github "$gh"
assert_eq "1" "$RC" "github: fail exits 1"
assert_match '^failing checks: ci$' "$(field .reason)" "github: reason lists the failing check"

echo "-- github: pending exits 8 with a reason"
SDLC_MOCK_CHECKS=pending run github "$gh"
assert_eq "8" "$RC" "github: pending exits 8"
assert_eq "pending" "$(field .status)" "github: status pending"
assert_match 'pending checks: ci' "$(field .reason)" "github: pending reason"

echo "-- github: zero checks fail closed even without required checks"
gh0="$EVAL_TMP/gh0"
mkrepo "$gh0" '{"version":1,"platform":"github","repo":{"owner":"mock-org","name":"mock-repo"}}'
SDLC_MOCK_CHECKS=empty run github "$gh0"
assert_eq "1" "$RC" "github: empty list exits 1"
assert_match 'no checks reported' "$(field .reason)" "github: empty list reason"
assert_eq "[]" "$(printf '%s' "$OUT" | jq -c .required)" "github: required is [] when unconfigured"

echo "-- github: only skipped checks and no required names -> every check was skipped"
SDLC_MOCK_CHECKS=skipped run github "$gh0"
assert_eq "1" "$RC" "github: skipped-only exits 1"
assert_eq "every check was skipped" "$(field .reason)" "github: skipped-only reason"

echo "-- github: all required checks pass"
ghok="$EVAL_TMP/ghok"
mkrepo "$ghok" '{"version":1,"platform":"github","repo":{"owner":"mock-org","name":"mock-repo"},"github":{"requiredChecks":["ci","lint"]}}'
SDLC_MOCK_CHECKS=pass run github "$ghok"
assert_eq "0" "$RC" "github: pass exits 0"
assert_eq "null" "$(field .reason)" "github: reason is null on pass"

echo "-- azure: the build policy for azure.pipelineName must be present and approved"
azcfg='{"version":1,"platform":"azure","repo":{"defaultBranch":"main"},"azure":{"organization":"https://dev.azure.com/mock-org","project":"mock-proj","repo":"mock-repo","pipelineName":"%s"}}'
az="$EVAL_TMP/az"
mkrepo "$az" "$(printf "$azcfg" missing-pipeline)"
SDLC_MOCK_CHECKS=pass run azure "$az"
assert_eq "1" "$RC" "azure: missing required build policy exits 1"
assert_eq "fail" "$(field .status)" "azure: status fail"
assert_match 'required checks missing or skipped: missing-pipeline' "$(field .reason)" "azure: reason names the pipeline"
assert_eq '["missing-pipeline"]' "$(printf '%s' "$OUT" | jq -c .required)" "azure: required is the configured pipeline name"

azok="$EVAL_TMP/azok"
mkrepo "$azok" "$(printf "$azcfg" sdlc-pr-review)"
SDLC_MOCK_CHECKS=pass run azure "$azok"
assert_eq "0" "$RC" "azure: 'Build (sdlc-pr-review)' satisfies the required name sdlc-pr-review"
assert_eq "null" "$(field .reason)" "azure: reason null on pass"
SDLC_MOCK_CHECKS=empty run azure "$azok"
assert_eq "1" "$RC" "azure: zero evaluations exit 1"
assert_match 'no checks reported' "$(field .reason)" "azure: empty reason"
SDLC_MOCK_CHECKS=skipped run azure "$azok"
assert_eq "1" "$RC" "azure: skipped-only exits 1"
assert_match 'required checks missing or skipped: sdlc-pr-review' "$(field .reason)" "azure: skipped required policy is reported"
SDLC_MOCK_CHECKS=pending run azure "$azok"
assert_eq "8" "$RC" "azure: pending exits 8"
SDLC_MOCK_CHECKS=fail run azure "$azok"
assert_eq "1" "$RC" "azure: rejected policy exits 1"
assert_match 'failing checks: Build \(sdlc-pr-review\)' "$(field .reason)" "azure: rejected reason names the evaluation"

echo "-- both: identical key sets"
SDLC_MOCK_CHECKS=pass run github "$ghok"; kg=$(printf '%s' "$OUT" | jq -c 'keys')
SDLC_MOCK_CHECKS=pass run azure "$azok"; ka=$(printf '%s' "$OUT" | jq -c 'keys')
assert_eq "$kg" "$ka" "pr_checks prints the same keys on both platforms ($kg)"

echo "-- a CLI failure is an error, not a verdict"
SDLC_MOCK_FAIL="pr checks" run github "$ghok"
assert_eq "1" "$RC" "github: gh failure exits 1"
assert_match 'ai-sdlc: gh pr checks 7 failed \(exit 1\)' "$ERR" "github: failure message names the command"
assert_eq "" "$OUT" "github: no JSON verdict on a CLI failure"
SDLC_MOCK_FAIL="repos pr policy" run azure "$azok"
assert_eq "1" "$RC" "azure: az failure exits 1"
assert_match 'ai-sdlc: az repos pr policy list --id 7 failed \(exit 1\)' "$ERR" "azure: failure message names the command"

echo "-- review.runner local: the review pipeline is no longer required, a custom build requirement still is"
azl="$EVAL_TMP/azl"
mkrepo "$azl" '{"version":1,"platform":"azure","repo":{"defaultBranch":"main"},"review":{"runner":"local"},"azure":{"organization":"https://dev.azure.com/mock-org","project":"mock-proj","repo":"mock-repo"}}'
SDLC_MOCK_CHECKS=pass run azure "$azl"
assert_eq "0" "$RC" "azure local without pipelineName: pass exits 0"
assert_eq "[]" "$(printf '%s' "$OUT" | jq -c .required)" "azure local without pipelineName: required is []"
SDLC_MOCK_CHECKS=empty run azure "$azl"
assert_eq "1" "$RC" "azure local: zero evaluations still fail closed"
azc="$EVAL_TMP/azc"
mkrepo "$azc" '{"version":1,"platform":"azure","repo":{"defaultBranch":"main"},"review":{"runner":"local"},"azure":{"organization":"https://dev.azure.com/mock-org","project":"mock-proj","repo":"mock-repo","pipelineName":"custom-ci"}}'
SDLC_MOCK_CHECKS=pass run azure "$azc"
assert_eq "1" "$RC" "azure local with a custom pipelineName: that pipeline is required and missing"
assert_eq '["custom-ci"]' "$(printf '%s' "$OUT" | jq -c .required)" "azure local: required is the custom pipeline"
azci="$EVAL_TMP/azci"
mkrepo "$azci" '{"version":1,"platform":"azure","repo":{"defaultBranch":"main"},"review":{"runner":"ci"},"azure":{"organization":"https://dev.azure.com/mock-org","project":"mock-proj","repo":"mock-repo"}}'
SDLC_MOCK_CHECKS=pass run azure "$azci"
assert_eq '["sdlc-pr-review"]' "$(printf '%s' "$OUT" | jq -c .required)" "azure ci without pipelineName: sdlc-pr-review is the default requirement"
ghl="$EVAL_TMP/ghl"
mkrepo "$ghl" '{"version":1,"platform":"github","repo":{"owner":"mock-org","name":"mock-repo"},"review":{"runner":"local"},"github":{"requiredChecks":[]}}'
SDLC_MOCK_CHECKS=pass run github "$ghl"
assert_eq "0" "$RC" "github local: other passing checks satisfy pr_checks"
SDLC_MOCK_CHECKS=empty run github "$ghl"
assert_eq "1" "$RC" "github local: zero checks still fail closed (a CI check must report on the PR)"

eval_done
