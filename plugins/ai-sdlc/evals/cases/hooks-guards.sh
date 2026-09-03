#!/usr/bin/env bash
# Each guardrail fires in an sdlc project: secrets, protected paths, FIX_MODE test edits,
# ticket gate, verifier read-only, production gate, post-edit lint.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
H="$P/hooks"
proj="$EVAL_TMP/proj"; mkdir -p "$proj/src" "$proj/secrets" "$proj/.github/workflows" "$proj/docs/adr" "$proj/.sdlc/features/x"
cp "$EVAL_ROOT/fixtures/sdlc-project/sdlc.config.json" "$EVAL_ROOT/fixtures/sdlc-project/lint-mock.sh" "$proj/"
git -C "$proj" init -q -b main; git -C "$proj" config user.email e@x; git -C "$proj" config user.name e; git -C "$proj" config core.autocrlf false
printf 'SECRET=1\n' >"$proj/.env"; printf 'EXAMPLE=\n' >"$proj/.env.example"; printf 'key\n' >"$proj/secrets/k.pem"
printf 'export const a = 1;\n' >"$proj/src/a.ts"; printf 'test("a", () => {});\n' >"$proj/src/a.test.ts"; printf 'name: ci\n' >"$proj/.github/workflows/ci.yml"
printf '# ADR\n' >"$proj/docs/adr/0001-x.md"; printf '# spec\n' >"$proj/.sdlc/features/x/spec.md"
( cd "$proj" && git add -A >/dev/null && git commit -q -m init )
sha=$(git -C "$proj" rev-parse HEAD)
cd "$proj" || exit 1
edit() { hook_json Edit "{\"file_path\":\"$proj/$1\",\"old_string\":\"a\",\"new_string\":\"b\"}" "$proj"; }
read_() { hook_json Read "{\"file_path\":\"$proj/$1\"}" "$proj"; }
bash_() { hook_json Bash "$(jq -cn --arg c "$1" '{command:$c}')" "$proj"; }
agent() { printf '%s' "$2" | jq -c --arg a "$1" '. + {agent_type:$a}'; }
expect() { local want="$1" label="$2" hook="$3" inp="$4"; run_hook "$H/$hook" "$inp"; if [ "$HOOK_EXIT" = "$want" ]; then _ok "$label (exit $HOOK_EXIT)"; else _fail "$label" "expected $want got $HOOK_EXIT; stderr: ${HOOK_ERR:0:200}"; fi; }

echo "-- guard-secrets"
expect 2 "Read .env denied"                       guard-secrets.sh "$(read_ .env)"
expect 0 "Read .env.example allowed"              guard-secrets.sh "$(read_ .env.example)"
expect 2 "Read secrets/k.pem denied"              guard-secrets.sh "$(read_ secrets/k.pem)"
expect 0 "Read src/a.ts allowed"                  guard-secrets.sh "$(read_ src/a.ts)"
expect 2 "Bash cat secrets file denied"           guard-secrets.sh "$(bash_ 'cat secrets/k.pem')"
expect 2 "Bash cat ~/.ssh/id_rsa denied"          guard-secrets.sh "$(bash_ 'cat ~/.ssh/id_rsa')"
expect 2 "Bash cat \$HOME/.aws/credentials denied" guard-secrets.sh "$(bash_ 'cat $HOME/.aws/credentials')"
expect 2 "Grep in secrets/ denied"                guard-secrets.sh "$(hook_json Grep "{\"pattern\":\"x\",\"path\":\"$proj/secrets\"}" "$proj")"
expect 0 "Bash npm test allowed"                  guard-secrets.sh "$(bash_ 'npm test')"
expect 2 "Bash echo of a token env var denied"    guard-secrets.sh "$(bash_ 'GH_TOKEN=abc curl -H x https://api.github.com')"
[[ "$HOOK_ERR" =~ ai-sdlc\ guardrail ]] && _ok "denial message is prefixed" || _fail "denial prefix" "$HOOK_ERR"

echo "-- guard-protected-paths"
expect 2 "Edit workflow denied"                   guard-protected-paths.sh "$(edit .github/workflows/ci.yml)"
expect 2 "Edit sdlc.config.json denied"           guard-protected-paths.sh "$(edit sdlc.config.json)"
expect 0 "Edit src/a.ts allowed"                  guard-protected-paths.sh "$(edit src/a.ts)"
expect 2 "Bash rm sdlc.config.json denied"        guard-protected-paths.sh "$(bash_ 'rm sdlc.config.json')"
expect 2 "Bash redirect into CODEOWNERS denied"   guard-protected-paths.sh "$(bash_ 'echo x > CODEOWNERS')"
expect 2 "Bash sed -i on workflow denied"         guard-protected-paths.sh "$(bash_ 'sed -i s/a/b/ .github/workflows/ci.yml')"
expect 0 "Bash cat sdlc.config.json allowed"      guard-protected-paths.sh "$(bash_ 'cat sdlc.config.json')"
expect 2 "Bash touch of the unlock marker denied" guard-protected-paths.sh "$(bash_ 'touch .sdlc/UNLOCK_PROTECTED')"
expect 2 "Write release marker denied"            guard-protected-paths.sh "$(hook_json Write "{\"file_path\":\"$proj/.sdlc/release/AUTHORIZED-$sha\",\"content\":\"x\"}" "$proj")"
touch "$proj/.sdlc/UNLOCK_PROTECTED"
expect 0 "human unlock marker allows the edit"    guard-protected-paths.sh "$(edit .github/workflows/ci.yml)"
rm "$proj/.sdlc/UNLOCK_PROTECTED"

echo "-- guard-test-edits"
expect 0 "test edit allowed without FIX_MODE"     guard-test-edits.sh "$(edit src/a.test.ts)"
touch "$proj/.sdlc/FIX_MODE"
expect 2 "test edit denied under FIX_MODE"        guard-test-edits.sh "$(edit src/a.test.ts)"
expect 2 "new test file denied under FIX_MODE"    guard-test-edits.sh "$(hook_json Write "{\"file_path\":\"$proj/src/__tests__/b.js\",\"content\":\"x\"}" "$proj")"
expect 0 "source edit allowed under FIX_MODE"     guard-test-edits.sh "$(edit src/a.ts)"
rm "$proj/.sdlc/FIX_MODE"

echo "-- guard-ticket-gate"
expect 2 "source edit denied without active ticket" guard-ticket-gate.sh "$(edit src/a.ts)"
[[ "$HOOK_ERR" =~ ACTIVE_TICKET ]] && _ok "reason names ACTIVE_TICKET" || _fail "reason" "$HOOK_ERR"
expect 0 "ADR edit allowed without ticket"        guard-ticket-gate.sh "$(edit docs/adr/0001-x.md)"
expect 0 "spec edit allowed without ticket"       guard-ticket-gate.sh "$(edit .sdlc/features/x/spec.md)"
expect 0 "CONTEXT.md edit allowed without ticket" guard-ticket-gate.sh "$(edit CONTEXT.md)"
printf '4711\n' >"$proj/.sdlc/ACTIVE_TICKET"
expect 0 "source edit allowed with active ticket" guard-ticket-gate.sh "$(edit src/a.ts)"
rm "$proj/.sdlc/ACTIVE_TICKET"
jq '.guardrails.requireTicket=false' sdlc.config.json >c.json && mv c.json sdlc.config.json
expect 0 "gate off by config"                     guard-ticket-gate.sh "$(edit src/a.ts)"
jq '.guardrails.requireTicket=true' sdlc.config.json >c.json && mv c.json sdlc.config.json

echo "-- guard-verifier-readonly"
expect 2 "verifier Edit denied"                   guard-verifier-readonly.sh "$(agent ai-sdlc:sdlc-verifier "$(edit src/a.ts)")"
expect 2 "verifier (bare name) Edit denied"       guard-verifier-readonly.sh "$(agent sdlc-verifier "$(edit src/a.ts)")"
expect 2 "auditor Write denied"                   guard-verifier-readonly.sh "$(agent ai-sdlc:sdlc-security-auditor "$(hook_json Write "{\"file_path\":\"$proj/x\",\"content\":\"\"}" "$proj")")"
expect 0 "verifier may run tests"                 guard-verifier-readonly.sh "$(agent ai-sdlc:sdlc-verifier "$(bash_ 'npm test -- --reporter=dot 2>&1 | tail -n 40')")"
expect 0 "verifier may read and grep"             guard-verifier-readonly.sh "$(agent ai-sdlc:sdlc-verifier "$(bash_ 'git diff main...HEAD --stat && grep -rn TODO src')")"
expect 2 "verifier redirect to file denied"       guard-verifier-readonly.sh "$(agent ai-sdlc:sdlc-verifier "$(bash_ 'npm test > result.txt')")"
expect 2 "verifier git commit denied"             guard-verifier-readonly.sh "$(agent ai-sdlc:sdlc-verifier "$(bash_ 'git add -A && git commit -m fix')")"
expect 2 "verifier sed -i denied"                 guard-verifier-readonly.sh "$(agent ai-sdlc:sdlc-verifier "$(bash_ 'sed -i s/a/b/ src/a.ts')")"
expect 0 "other agents are not restricted"        guard-verifier-readonly.sh "$(agent Explore "$(edit src/a.ts)")"
expect 0 "main thread is not restricted"          guard-verifier-readonly.sh "$(edit src/a.ts)"

echo "-- gate-production"
expect 2 "git push main denied without authorisation" gate-production.sh "$(bash_ 'git push origin main')"
[[ "$HOOK_ERR" =~ sdlc-ship ]] && _ok "reason points at /ai-sdlc:sdlc-ship" || _fail "reason" "$HOOK_ERR"
expect 2 "az pipelines run denied"                gate-production.sh "$(bash_ 'az pipelines run --name deploy')"
expect 2 "kubectl apply denied"                   gate-production.sh "$(bash_ 'kubectl apply -f k8s/')"
expect 2 "chained deploy denied"                  gate-production.sh "$(bash_ 'npm test && git push origin main')"
expect 0 "git push feature branch allowed"        gate-production.sh "$(bash_ 'git push origin feature/x')"
expect 0 "git status allowed"                     gate-production.sh "$(bash_ 'git status')"
mkdir -p "$proj/.sdlc/release"
printf 'authorised_by=human\nexpires=%s\n' "$(( $(date +%s) + 7200 ))" >"$proj/.sdlc/release/AUTHORIZED-$sha"
expect 0 "git push main allowed with fresh authorisation" gate-production.sh "$(bash_ 'git push origin main')"
printf 'authorised_by=human\nexpires=%s\n' "$(( $(date +%s) - 60 ))" >"$proj/.sdlc/release/AUTHORIZED-$sha"
expect 2 "expired authorisation denies"           gate-production.sh "$(bash_ 'git push origin main')"
[[ "$HOOK_ERR" =~ expired ]] && _ok "reason says expired" || _fail "reason" "$HOOK_ERR"
rm "$proj/.sdlc/release/AUTHORIZED-$sha"
printf 'expires=%s\n' "$(( $(date +%s) + 7200 ))" >"$proj/.sdlc/release/AUTHORIZED-0000000"
expect 2 "authorisation for another commit denies" gate-production.sh "$(bash_ 'git push origin main')"

echo "-- post-edit-verify"
printf 'export const a = 1; // LINTFAIL\n' >"$proj/src/bad.ts"
run_hook "$H/post-edit-verify.sh" "$(edit src/bad.ts)"
assert_eq "2" "$HOOK_EXIT" "lint failure surfaces as exit 2"
assert_match 'LINTFAIL token present' "$HOOK_ERR" "linter output is shown to Claude"
run_hook "$H/post-edit-verify.sh" "$(edit src/a.ts)"
assert_eq "0" "$HOOK_EXIT" "clean file passes lint"
run_hook "$H/post-edit-verify.sh" "$(edit docs/adr/0001-x.md)"
assert_eq "0" "$HOOK_EXIT" "non-source file is skipped"
jq 'del(.commands.lint)' sdlc.config.json >c.json && mv c.json sdlc.config.json
run_hook "$H/post-edit-verify.sh" "$(edit src/bad.ts)"
assert_eq "0" "$HOOK_EXIT" "no lint configured: silent"

echo "-- fail closed"
run_hook "$H/guard-secrets.sh" 'not json'
assert_eq "2" "$HOOK_EXIT" "guard denies on malformed input"
run_hook "$H/post-edit-verify.sh" 'not json'
assert_eq "0" "$HOOK_EXIT" "post hook fails open on malformed input"

eval_done
