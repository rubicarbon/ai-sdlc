#!/usr/bin/env bash
# The isolation helper is the verifier's optional tool for HEAD evidence: it runs
# commands.verify in a disposable worktree, never in the main checkout, and proves afterwards
# that the main checkout did not change.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
HELPER="$P/scripts/verify/run-isolated.sh"
proj="$EVAL_TMP/proj"; mkdir -p "$proj/src" "$proj/.sdlc"
git -C "$proj" init -q -b main; git -C "$proj" config user.email e@x; git -C "$proj" config user.name e; git -C "$proj" config core.autocrlf false
cat >"$proj/sdlc.config.json" <<'JSON'
{"version":1,"platform":"none","tier":1,"commands":{"verify":"bash verify.sh","verifySetup":"bash setup.sh"},
 "artifacts":{"dir":".sdlc"}}
JSON
printf 'export const a = 1;\n' >"$proj/src/a.ts"
printf 'echo setup-ran > setup.marker\n' >"$proj/setup.sh"
printf 'set -e\ntest -f setup.marker\necho verify-ok\necho generated > build.out\n' >"$proj/verify.sh"
printf '.sdlc/tmp/\n' >"$proj/.gitignore"
( cd "$proj" && git add -A >/dev/null && git commit -q -m init )
cd "$proj" || exit 1
tree_hash() { ( cd "$1" && find . -path ./.git -prune -o -path ./.sdlc/tmp -prune -o -type f -print | LC_ALL=C sort | while read -r f; do printf '%s ' "$f"; sha256sum "$f" | cut -d' ' -f1; done ) | sha256sum | cut -d' ' -f1; }

echo "-- isolation helper"
h0=$(tree_hash "$proj")
out=$(bash "$HELPER" --tail 5 2>"$EVAL_TMP/helper.err"); rc=$?
assert_eq "0" "$rc" "helper exits 0 when verify passes ($(head -c 200 "$EVAL_TMP/helper.err"))"
assert_eq "0" "$(jq -r .exit <<<"$out")" "verify exit code reported"
assert_eq "true" "$(jq -r .main_checkout_unchanged <<<"$out")" "main checkout reported unchanged"
assert_eq "false" "$(jq -r .dirty_main_checkout <<<"$out")" "clean main checkout reported"
assert_match 'verify-ok' "$(jq -r '.tail | join("\n")' <<<"$out")" "verify output tail captured"
assert_match 'setup-ran|== setup' "$(cat "$(jq -r .log <<<"$out")")" "setup command ran in the worktree (log)"
assert_eq "$h0" "$(tree_hash "$proj")" "main checkout byte-identical after the run"
assert_no_file "$proj/build.out" "verify output landed in the worktree, not the main checkout"
assert_no_file "$proj/setup.marker" "setup output landed in the worktree, not the main checkout"
assert_eq "" "$(cd "$proj" && git status --porcelain)" "git status clean after the run"
assert_eq "1" "$(git -C "$proj" worktree list | wc -l | tr -d ' ')" "disposable worktree removed"
assert_eq "0" "$(find "$proj/.sdlc/tmp" -maxdepth 1 -type d -name 'sdlc-verify.*' | wc -l | tr -d ' ')" "worktree directory cleaned up"

# failing verify command -> exit 1, still clean
printf 'echo boom >&2\nexit 3\n' >"$proj/verify.sh"; ( cd "$proj" && git commit -qam fail )
out=$(bash "$HELPER" 2>/dev/null); rc=$?
assert_eq "1" "$rc" "helper exits 1 when verify fails"
assert_eq "3" "$(jq -r .exit <<<"$out")" "verify exit code 3 reported"
assert_eq "" "$(cd "$proj" && git status --porcelain)" "still clean after a failing run"

# a verify command that reaches back into the main checkout is detected: exit 4
printf 'echo tampered >> "$SDLC_MAIN/src/a.ts"\n' >"$proj/verify.sh"; ( cd "$proj" && git commit -qam escape )
out=$(SDLC_MAIN="$proj" bash "$HELPER" 2>"$EVAL_TMP/escape.err"); rc=$?
assert_eq "4" "$rc" "helper exits 4 when the main checkout changed during the run"
assert_eq "false" "$(jq -r .main_checkout_unchanged <<<"$out")" "change reported in JSON"
assert_match 'main checkout changed' "$(cat "$EVAL_TMP/escape.err")" "stderr names the escape"
( cd "$proj" && git checkout -q -- src/a.ts )

# untracked files count as state too
printf 'echo x\n' >"$proj/verify.sh"; ( cd "$proj" && git commit -qam ok )
printf 'scratch\n' >"$proj/untracked.txt"
printf 'echo more >> "$SDLC_MAIN/untracked.txt"\n' >"$proj/verify.sh"; ( cd "$proj" && git commit -qam escape2 )
out=$(SDLC_MAIN="$proj" bash "$HELPER" 2>/dev/null); rc=$?
assert_eq "4" "$rc" "untracked file modification is detected"
rm -f "$proj/untracked.txt"

# dirty main checkout is reported, uncommitted change is not what gets verified
printf 'echo x\n' >"$proj/verify.sh"; ( cd "$proj" && git commit -qam ok2 )
printf 'dirty\n' >>"$proj/src/a.ts"
out=$(bash "$HELPER" 2>/dev/null); rc=$?
assert_eq "0" "$rc" "dirty checkout still runs HEAD"
assert_eq "true" "$(jq -r .dirty_main_checkout <<<"$out")" "dirty main checkout reported"
( cd "$proj" && git checkout -q -- src/a.ts )

# usage errors
out=$(bash "$HELPER" --ref no-such-rev 2>&1); rc=$?
assert_eq "2" "$rc" "unknown revision is a usage error"
out=$(cd "$EVAL_TMP" && bash "$HELPER" 2>&1); rc=$?
assert_eq "2" "$rc" "outside an sdlc project the helper refuses"

eval_done
