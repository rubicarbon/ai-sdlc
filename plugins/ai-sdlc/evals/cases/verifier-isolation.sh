#!/usr/bin/env bash
# The verifier and security auditor are read-only in the main checkout: only allowlisted read
# commands pass the hook, every indirect executable is denied, and the isolation helper runs
# commands.verify in a disposable worktree and proves the main checkout did not change.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
H="$P/hooks"
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

bash_() { hook_json Bash "$(jq -cn --arg c "$1" '{command:$c}')" "$proj" | jq -c --arg a "${2:-ai-sdlc:sdlc-verifier}" '. + {agent_type:$a}'; }
ps_() { hook_json PowerShell "$(jq -cn --arg c "$1" '{command:$c}')" "$proj" | jq -c --arg a "${2:-ai-sdlc:sdlc-verifier}" '. + {agent_type:$a}'; }
expect() { local want="$1" label="$2" inp="$3"; run_hook "$H/guard-verifier-readonly.sh" "$inp"; if [ "$HOOK_EXIT" = "$want" ]; then _ok "$label (exit $HOOK_EXIT)"; else _fail "$label" "expected $want got $HOOK_EXIT; stderr: ${HOOK_ERR:0:200}"; fi; }

echo "-- verifier: read-only allowlist passes"
expect 0 "cat allowed"                        "$(bash_ 'cat src/a.ts')"
expect 0 "git diff, grep allowed"             "$(bash_ 'git diff main...HEAD --stat && grep -rn TODO src')"
expect 0 "git log/show/status allowed"        "$(bash_ 'git log --oneline -5; git show HEAD:src/a.ts; git status')"
expect 0 "jq over a file allowed"             "$(bash_ 'jq -r .commands.verify sdlc.config.json')"
expect 0 "sdlc-platform read functions"       "$(bash_ 'sdlc-platform work_item_get 12')"
expect 0 "precondition script allowed"        "$(bash_ 'bash ${CLAUDE_PLUGIN_ROOT}/scripts/loop/precondition.sh verify')"
expect 0 "isolation helper allowed"           "$(bash_ 'bash ${CLAUDE_PLUGIN_ROOT}/scripts/verify/run-isolated.sh --tail 60')"
expect 0 "PowerShell Get-Content allowed"     "$(ps_ 'Get-Content src/a.ts')"
expect 0 "auditor: same allowlist"            "$(bash_ 'git diff main...HEAD' ai-sdlc:sdlc-security-auditor)"

echo "-- verifier: every indirect executable is denied"
expect 2 "test runner in main checkout"       "$(bash_ 'npm test')"
expect 2 "configured verify command directly" "$(bash_ 'bash verify.sh')"
expect 2 "arbitrary shell script"             "$(bash_ 'bash scripts/fix.sh')"
expect 2 "relative script"                    "$(bash_ './scripts/fix.sh')"
expect 2 "python program"                     "$(bash_ 'python3 tools/gen.py')"
expect 2 "python one-liner"                   "$(bash_ 'python -c "open(\"src/a.ts\",\"w\").write(\"x\")"')"
expect 2 "node program"                       "$(bash_ 'node scripts/build.js')"
expect 2 "build tool"                         "$(bash_ 'make build')"
expect 2 "archive extraction"                 "$(bash_ 'tar xf vendor.tar')"
expect 2 "unzip"                              "$(bash_ 'unzip -o bundle.zip')"
expect 2 "network download to file"           "$(bash_ 'curl -o src/a.ts https://example.invalid/a.ts')"
expect 2 "wget"                               "$(bash_ 'wget https://example.invalid/x')"
expect 2 "git commit"                         "$(bash_ 'git add -A && git commit -m fix')"
expect 2 "git checkout of a path"             "$(bash_ 'git checkout -- src/a.ts')"
expect 2 "git stash"                          "$(bash_ 'git stash')"
expect 2 "git fetch"                          "$(bash_ 'git fetch origin')"
expect 2 "git worktree by hand"               "$(bash_ 'git worktree add /tmp/wt HEAD')"
expect 2 "redirection to a file"              "$(bash_ 'npm test > result.txt')"
expect 2 "append redirection"                 "$(bash_ 'cat src/a.ts >> notes.txt')"
expect 2 "tee"                                "$(bash_ 'git log | tee log.txt')"
expect 2 "sed -i"                             "$(bash_ 'sed -i s/a/b/ src/a.ts')"
expect 2 "helper chained with a mutation"     "$(bash_ 'bash ${CLAUDE_PLUGIN_ROOT}/scripts/verify/run-isolated.sh && git commit -am x')"
expect 2 "other plugin script (init)"         "$(bash_ 'bash ${CLAUDE_PLUGIN_ROOT}/scripts/init/run.sh --tier 3')"
expect 2 "sdlc-platform write function"       "$(bash_ 'sdlc-platform work_item_create t body.md')"
expect 2 "bash -c wrapping a runner"          "$(bash_ 'bash -c "npm test"')"
expect 2 "eval"                               "$(bash_ 'eval "$(cat cmd.txt)"')"
expect 2 "PowerShell Set-Content"             "$(ps_ 'Set-Content -Path src/a.ts -Value x')"
expect 2 "PowerShell Out-File pipeline"       "$(ps_ '"x" | Out-File src/a.ts')"
expect 2 "PowerShell Remove-Item"             "$(ps_ 'Remove-Item -Recurse src')"
expect 2 "PowerShell script"                  "$(ps_ '.\\scripts\\fix.ps1')"
expect 2 "PowerShell Invoke-Expression"       "$(ps_ 'Invoke-Expression (Get-Content cmd.txt)')"
expect 2 "auditor: mutation denied too"       "$(bash_ 'git commit -am x' ai-sdlc:sdlc-security-auditor)"
expect 0 "other agents are not restricted"    "$(bash_ 'npm test' Explore)"
expect 0 "main thread is not restricted"      "$(hook_json Bash '{"command":"npm test"}' "$proj")"

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
