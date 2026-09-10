#!/usr/bin/env bash
# scripts/review/*: the snapshot is the exact PR head in an isolated worktree, one review per
# PR and sha at a time, the assembled report has one summed summary line, finalize publishes only
# a validated and posted report and records every failure, and the gate selects only the
# PR-bound report under review.runner local.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
S="$P/scripts/review"; ST="$S/status.sh"
export SDLC_PLATFORM_MOCK=1 SDLC_MOCK_STATE="$EVAL_TMP/state"; mkdir -p "$SDLC_MOCK_STATE"

bare="$EVAL_TMP/origin.git"; git init -q --bare -b main "$bare"
proj="$EVAL_TMP/proj"; git clone -q "$bare" "$proj" 2>/dev/null
git -C "$proj" config user.email e@x; git -C "$proj" config user.name e; git -C "$proj" config core.autocrlf false
printf '{"version":1,"platform":"github","tier":3,"repo":{"owner":"mock-org","name":"mock-repo","defaultBranch":"main"},"commands":{"verify":"true"},"review":{"runner":"local","nitCap":5},"artifacts":{"dir":".sdlc"}}\n' >"$proj/sdlc.config.json"
printf '.sdlc/tmp/\n' >"$proj/.gitignore"; printf 'a\n' >"$proj/a.txt"
git -C "$proj" add -A >/dev/null; git -C "$proj" commit -q -m init; git -C "$proj" push -q origin main 2>/dev/null
git -C "$proj" checkout -q -b feat/x; printf 'b\n' >"$proj/b.txt"; git -C "$proj" add -A; git -C "$proj" commit -q -m feat
git -C "$proj" push -q -u origin feat/x 2>/dev/null
head=$(git -C "$proj" rev-parse HEAD); base=$(git -C "$proj" rev-parse main)
export SDLC_MOCK_PR_HEAD_SHA="$head"
cd "$proj" || exit 1
tree_hash() { ( git status --porcelain; git rev-parse HEAD; cat a.txt ) | sha256sum | cut -d' ' -f1; }

echo "-- snapshot: the exact PR head while the author's checkout differs and is dirty"
printf 'dirty\n' >>a.txt; git checkout -q main
before=$(tree_hash)
id=$(bash "$ST" new --branch feat/x --pr 42 --trigger manual)
snap=$(bash "$S/snapshot.sh" --launch "$id" --pr 42 --head-sha "$head" --base-sha "$base" --head-repo-url "$bare" --head-ref feat/x 2>"$EVAL_TMP/err"); rc=$?
assert_eq "0" "$rc" "snapshot exits 0 ($(cat "$EVAL_TMP/err"))"
wt=$(jq -r .dir <<<"$snap")
assert_eq "$head" "$(git -C "$wt" rev-parse HEAD)" "worktree is at the PR head"
assert_file "$wt/b.txt" "worktree holds the head's files"
assert_eq "a" "$(cat "$wt/a.txt")" "worktree has the committed content, not the dirty edit"
assert_eq "$before" "$(tree_hash)" "author checkout untouched (still on main, still dirty)"
assert_eq "$head $base" "$(jq -r '"\(.head_sha) \(.base_sha)"' <<<"$snap")" "snapshot reports head and base"
assert_eq "$head" "$(bash "$ST" get --launch "$id" --field head_sha)" "launch record carries the head sha"
echo "-- snapshot: one live review per PR and sha"
id2=$(bash "$ST" new --branch feat/x --pr 42)
bash "$S/snapshot.sh" --launch "$id2" --pr 42 --head-sha "$head" --base-sha "$base" --head-repo-url "$bare" --head-ref feat/x >/dev/null 2>&1; rc=$?
assert_eq "5" "$rc" "second snapshot of the same PR/sha exits 5"
assert_eq "skipped duplicate" "$(bash "$ST" get --launch "$id2" --field state)" "duplicate launch is marked skipped duplicate"
echo "-- snapshot: head moved"
id3=$(bash "$ST" new --branch feat/x --pr 43)
bash "$S/snapshot.sh" --launch "$id3" --pr 43 --head-sha 3333333333333333333333333333333333333333 --base-sha "$base" --head-repo-url "$bare" --head-ref feat/x >/dev/null 2>"$EVAL_TMP/err"; rc=$?
assert_eq "3" "$rc" "fetched head differs from the reported sha: exit 3"
assert_match 'moved' "$(cat "$EVAL_TMP/err")" "reason says the PR moved"
assert_eq "failed head-moved" "$(bash "$ST" get --launch "$id3" --field state)" "state failed head-moved"

echo "-- assemble: one summed summary line"
printf '# Security review: PR 42 against main\n**Commit:** %s  **Base:** main\n\nBlocking: 1  Important: 0  Nit: 1 (cap 5)\n\n## Blocking\n- `b.txt:1` (injection): bad. Fix: x.\n\n## Important\n- none\n\n## Nit\n- `a.txt:1` (style): meh.\n\n## Dependencies\n| Package | Version | Justified in PR | Notes |\n\nFindings are advisory; a human code owner approves the merge.\n' "$head" >"$EVAL_TMP/sec.md"
printf '## Missing\n- `b.txt` (requirement 2): not implemented. Fix: implement.\n\n## Partial\n- none\n\n## Not asked for\n- `b.txt:1` (scope): extra file.\n' >"$EVAL_TMP/spec.md"
tmp=".sdlc/tmp/review/wt-$id.report.md"
out=$(bash "$S/assemble.sh" --security "$EVAL_TMP/sec.md" --spec "$EVAL_TMP/spec.md" --head "$head" --base "$base" --pr 42 --cap 5 --out "$tmp" 2>&1); rc=$?
assert_eq "0" "$rc" "assemble exits 0 ($out)"
assert_eq "1" "$(grep -cE '^Blocking:' "$tmp")" "exactly one Blocking summary line"
assert_match '^Blocking: 2  Important: 1  Nit: 1 \(cap 5\)$' "$(grep -E '^Blocking:' "$tmp")" "summary sums security (1 Blocking) and spec (1 Missing -> Blocking, 1 Not asked for -> Important)"
assert_eq "1" "$(grep -c '^\*\*Commit:\*\*' "$tmp")" "exactly one Commit line"
assert_match "^\\*\\*Commit:\\*\\* $head" "$(grep '^\*\*Commit:\*\*' "$tmp")" "Commit line is the reviewed head"
assert_eq "1" "$(grep -c '^## Spec compliance' "$tmp")" "spec compliance section present"
assert_eq "1" "$(grep -c 'Advisory review by ai-sdlc; a human code owner approves' "$tmp")" "advisory sentence present once"
assert_eq "0" "$(grep -c 'approves the merge' "$tmp")" "auditor's own advisory sentence dropped"
assert_exit 0 "assembled report validates" -- bash "$P/scripts/loop/validate-report.sh" "$tmp" --security --head "$head"
printf '# nothing ranked\n' >"$EVAL_TMP/nosec.md"
assert_exit 1 "auditor report without ranked sections is rejected" -- bash "$S/assemble.sh" --security "$EVAL_TMP/nosec.md" --spec "$EVAL_TMP/spec.md" --head "$head" --base "$base" --pr 42 --cap 5 --out "$EVAL_TMP/x.md"
out=$(bash "$S/assemble.sh" --security "$EVAL_TMP/sec.md" --spec /nonexistent --head "$head" --base "$base" --pr 42 --cap 5 --out "$EVAL_TMP/nospec.md")
assert_match 'No spec found' "$(cat "$EVAL_TMP/nospec.md")" "missing spec file yields a 'No spec found' section, not a pass"
assert_match '^Blocking: 1  Important: 0' "$(grep -E '^Blocking:' "$EVAL_TMP/nospec.md")" "without a spec only the security counts remain"

echo "-- finalize: validate, re-check the head, post, publish atomically"
bash "$ST" set "$id" saved >/dev/null
final=".sdlc/verify/2026-09-10-${head:0:12}-pr42-security.md"
out=$(bash "$S/finalize.sh" --launch "$id" --report "$tmp" --publish "$final" --pr 42 --head-sha "$head" 2>"$EVAL_TMP/err"); rc=$?
assert_eq "0" "$rc" "finalize exits 0 ($(cat "$EVAL_TMP/err"))"
assert_file "$final" "report published"
assert_no_file "$tmp" "tmp report moved, not copied"
assert_eq "posted" "$(bash "$ST" get --launch "$id" --field state)" "state posted"
assert_eq "posted" "$(jq -r .state <<<"$out")" "finalize reports posted"
assert_eq "1" "$(jq -r .comment_id <<<"$out")" "comment posted through pr_comment"
assert_eq "$head" "$(bash "$ST" get --map feat/x --field last_sha)" "branch mapping records the reviewed sha"
assert_no_file ".sdlc/tmp/review/lock-42-${head:0:12}" "lock released after posting"
bash "$S/snapshot.sh" --cleanup --launch "$id"
assert_no_file "$wt" "worktree removed on cleanup"
echo "-- finalize failure paths publish nothing"
id4=$(bash "$ST" new --branch feat/x --pr 42); bash "$ST" attach "$id4" --pr 42 --head-sha "$head" >/dev/null
printf '# bad\n\nBlocking: many\n' >"$EVAL_TMP/bad.md"
bash "$S/finalize.sh" --launch "$id4" --report "$EVAL_TMP/bad.md" --publish .sdlc/verify/bad-pr42-security.md --pr 42 --head-sha "$head" >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "invalid report: exit 1"
assert_match '^failed validate:' "$(bash "$ST" get --launch "$id4" --field state)" "invalid report: state failed validate"
assert_no_file .sdlc/verify/bad-pr42-security.md "invalid report: nothing published"
id5=$(bash "$ST" new --branch feat/x --pr 42); bash "$ST" attach "$id5" --pr 42 --head-sha "$head" >/dev/null
cp "$final" "$EVAL_TMP/t5.md"
SDLC_MOCK_PR_HEAD_SHA=3333333333333333333333333333333333333333 bash "$S/finalize.sh" --launch "$id5" --report "$EVAL_TMP/t5.md" --publish .sdlc/verify/stale-pr42-security.md --pr 42 --head-sha "$head" >/dev/null 2>&1; rc=$?
assert_eq "4" "$rc" "head moved between snapshot and finalize: exit 4"
assert_eq "stale" "$(bash "$ST" get --launch "$id5" --field state)" "state stale"
assert_eq "1" "$(grep -c '^\*\*Status:\*\* stale' "$EVAL_TMP/t5.md")" "tmp report marked Status: stale"
assert_no_file .sdlc/verify/stale-pr42-security.md "stale report not published"
assert_exit 1 "a stale report never validates" -- bash "$P/scripts/loop/validate-report.sh" "$EVAL_TMP/t5.md" --security --head "$head"
id6=$(bash "$ST" new --branch feat/x --pr 42); bash "$ST" attach "$id6" --pr 42 --head-sha "$head" >/dev/null
cp "$final" "$EVAL_TMP/t6.md"
SDLC_MOCK_FAIL="pr comment" bash "$S/finalize.sh" --launch "$id6" --report "$EVAL_TMP/t6.md" --publish .sdlc/verify/post-pr42-security.md --pr 42 --head-sha "$head" >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "comment failure: exit 1"
assert_match '^failed post:' "$(bash "$ST" get --launch "$id6" --field state)" "comment failure: state failed post"
assert_file "$EVAL_TMP/t6.md" "comment failure: tmp report kept for a retry"
assert_no_file .sdlc/verify/post-pr42-security.md "comment failure: nothing published"

echo "-- status lifecycle"
assert_exit 0 "posted is terminal" -- bash "$ST" is_terminal posted
assert_exit 1 "saved is not terminal on a hosted platform" -- bash "$ST" is_terminal saved
assert_exit 0 "failed <reason> is terminal" -- bash "$ST" is_terminal "failed post: x"
assert_exit 0 "skipped duplicate is terminal" -- bash "$ST" is_terminal "skipped duplicate"
assert_exit 1 "running is not terminal" -- bash "$ST" is_terminal running
idl=$(bash "$ST" new --branch feat/x --pr 77)
assert_exit 0 "lock is free for a new launch" -- bash "$ST" lock 77 abcdef123456 "$idl"
idl2=$(bash "$ST" new --branch feat/x --pr 77)
assert_exit 1 "lock held by a live launch refuses" -- bash "$ST" lock 77 abcdef123456 "$idl2"
bash "$ST" set "$idl" abandoned x >/dev/null
assert_exit 0 "lock held by a terminal launch is taken over" -- bash "$ST" lock 77 abcdef123456 "$idl2"
bash "$ST" set "$idl2" posted x >/dev/null; bash "$ST" sweep
assert_no_file ".sdlc/tmp/review/lock-77-abcdef123456" "sweep removes locks of terminal launches"
assert_eq "$idl2" "$(bash "$ST" get --pr 77 --field launch_id)" "get --pr returns the newest launch"

echo "-- gate selection under review.runner local"
V=".sdlc/verify"; R="$P/scripts/loop"
printf '# Security review\n**Commit:** %s\n\nBlocking: 0  Important: 0  Nit: 0 (cap 5)\n' "$head" >"$V/2026-09-11-${head:0:7}-security.md"   # a newer security-only report
touch -t 203001010000 "$V/2026-09-11-${head:0:7}-security.md"
git checkout -q feat/x 2>/dev/null; git stash -q 2>/dev/null || true
printf '# Verification: x\n\n**Verdict:** PASS\n**Commit:** %s  **Base:** main\n**Tree:** clean\n' "$head" >"$V/2026-09-10-${head:0:7}.md"
out=$(bash "$R/precondition.sh" ship --pr 42); rc=$?
assert_eq "2" "$rc" "ship blocked: the PR-bound report has Blocking 2 (the newer security-only report does not count)"
assert_match "pr42-security.md has Blocking: 2" "$out" "reason names the PR-bound report and its count"
sed -i.bak 's/^Blocking: 2 /Blocking: 0 /' "$final" && rm -f "$final.bak"
out=$(bash "$R/precondition.sh" ship --pr 42); rc=$?
assert_eq "0" "$rc" "ship may start with the PR-bound report at Blocking 0 ($out)"
assert_match 'pr42-security.md has Blocking: 0' "$out" "success names the PR-bound report"
out=$(bash "$R/precondition.sh" ship); rc=$?
assert_eq "0" "$rc" "without --pr the branch mapping resolves the PR ($out)"
rm -f .sdlc/tmp/review/branch-*.json
for f in .sdlc/tmp/review/launch-*.json; do rm -f "$f"; done
out=$(bash "$R/precondition.sh" ship); rc=$?
assert_eq "2" "$rc" "without --pr and without a mapping the gate fails closed"
assert_match 'needs the pull request id' "$out" "reason asks for --pr"
out=$(bash "$R/precondition.sh" ship --pr 99); rc=$?
assert_eq "2" "$rc" "a PR without a report is blocked even though other security reports exist"
assert_match 'no PR-bound security report' "$out" "reason says no PR-bound report"
out=$(cd "$proj" && bash "$P/scripts/ship/preflight.sh" --pr 42 2>/dev/null)
assert_eq "true" "$(jq -r '.gates[] | select(.gate=="security review without Blocking findings") | .ok' <<<"$out")" "preflight selects the PR-bound report"
assert_match 'pr42-security.md' "$(jq -r '.gates[] | select(.gate=="security review without Blocking findings") | .evidence' <<<"$out")" "preflight evidence names it"
jq '.review.runner="ci"' sdlc.config.json >c.json && mv c.json sdlc.config.json
out=$(cd "$proj" && bash "$P/scripts/ship/preflight.sh" --pr 42 2>/dev/null)
assert_match "${head:0:7}-security.md" "$(jq -r '.gates[] | select(.gate=="security review without Blocking findings") | .evidence' <<<"$out")" "runner ci still picks the newest *-security.md"
eval_done
