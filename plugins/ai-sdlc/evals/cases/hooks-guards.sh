#!/usr/bin/env bash
# Each guardrail fires in an sdlc project: secrets (defaults, [] and a configured list),
# protected paths (nothing by default, the release markers always, a configured list), the
# verifier's file tools, the production gate (configured patterns only). Routine development
# (source, tests, lockfiles, CI files, installs, scripts, staging) passes every hook with no
# marker file present.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
H="$P/hooks"
proj="$EVAL_TMP/proj"; mkdir -p "$proj/src" "$proj/secrets" "$proj/.github/workflows" "$proj/docs/adr" "$proj/.sdlc/features/x" "$proj/certs" "$proj/keys" "$proj/config" "$proj/test/fixtures" "$proj/vault"
cp "$EVAL_ROOT/fixtures/sdlc-project/sdlc.config.json" "$proj/"
git -C "$proj" init -q -b main; git -C "$proj" config user.email e@x; git -C "$proj" config user.name e; git -C "$proj" config core.autocrlf false
printf 'SECRET=1\n' >"$proj/.env"; printf 'EXAMPLE=\n' >"$proj/.env.example"; printf 'key\n' >"$proj/secrets/k.pem"
printf 'cert\n' >"$proj/certs/server.crt"; printf 'chain\n' >"$proj/certs/fullchain.pem"; printf 'key\n' >"$proj/certs/server-key.pem"; printf 'key\n' >"$proj/certs/privkey.pem"
printf 'key\n' >"$proj/keys/id_rsa"; printf 'pub\n' >"$proj/keys/id_rsa.pub"; printf 'key\n' >"$proj/test/fixtures/id_rsa"
printf '{}\n' >"$proj/config/credentials.json"; printf '{}\n' >"$proj/config/credentials.json.example"
printf 't\n' >"$proj/vault/token"; printf 't\n' >"$proj/vault/token.example"
printf 'export const a = 1;\n' >"$proj/src/a.ts"; printf 'test("a", () => {});\n' >"$proj/src/a.test.ts"; printf 'name: ci\n' >"$proj/.github/workflows/ci.yml"
printf '{}\n' >"$proj/package-lock.json"; printf '* @owner\n' >"$proj/CODEOWNERS"; mkdir -p "$proj/.claude"; printf '{}\n' >"$proj/.claude/settings.json"
printf '# ADR\n' >"$proj/docs/adr/0001-x.md"; printf '# spec\n' >"$proj/.sdlc/features/x/spec.md"
( cd "$proj" && git add -A >/dev/null && git commit -q -m init )
sha=$(git -C "$proj" rev-parse HEAD)
cd "$proj" || exit 1
edit() { hook_json Edit "{\"file_path\":\"$proj/$1\",\"old_string\":\"a\",\"new_string\":\"b\"}" "$proj"; }
write_() { hook_json Write "{\"file_path\":\"$proj/$1\",\"content\":\"x\"}" "$proj"; }
read_() { hook_json Read "{\"file_path\":\"$proj/$1\"}" "$proj"; }
bash_() { hook_json Bash "$(jq -cn --arg c "$1" '{command:$c}')" "$proj"; }
ps_() { hook_json PowerShell "$(jq -cn --arg c "$1" '{command:$c}')" "$proj"; }
agent() { printf '%s' "$2" | jq -c --arg a "$1" '. + {agent_type:$a}'; }
cfg() { jq "$1" sdlc.config.json >c.json && mv c.json sdlc.config.json; }
expect() { local want="$1" label="$2" hook="$3" inp="$4"; run_hook "$H/$hook" "$inp"; if [ "$HOOK_EXIT" = "$want" ]; then _ok "$label (exit $HOOK_EXIT)"; else _fail "$label" "expected $want got $HOOK_EXIT; stderr: ${HOOK_ERR:0:200}"; fi; }

echo "-- guard-secrets: defaults"
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
echo "-- guard-secrets: certificates and public keys are not secrets, private keys are"
expect 0 "Read certs/server.crt allowed"          guard-secrets.sh "$(read_ certs/server.crt)"
expect 0 "Read certs/fullchain.pem allowed"       guard-secrets.sh "$(read_ certs/fullchain.pem)"
expect 0 "Read keys/id_rsa.pub allowed"           guard-secrets.sh "$(read_ keys/id_rsa.pub)"
expect 0 "Bash cat keys/id_rsa.pub allowed"       guard-secrets.sh "$(bash_ 'cat keys/id_rsa.pub')"
expect 2 "Read certs/server-key.pem denied"       guard-secrets.sh "$(read_ certs/server-key.pem)"
expect 2 "Read certs/privkey.pem denied"          guard-secrets.sh "$(read_ certs/privkey.pem)"
expect 2 "Read keys/id_rsa denied"                guard-secrets.sh "$(read_ keys/id_rsa)"
expect 2 "Bash cat keys/id_rsa denied"            guard-secrets.sh "$(bash_ 'cat keys/id_rsa')"
expect 2 "Read config/credentials.json denied"    guard-secrets.sh "$(read_ config/credentials.json)"
expect 0 "Read config/credentials.json.example allowed" guard-secrets.sh "$(read_ config/credentials.json.example)"
expect 2 "Read test/fixtures/id_rsa denied (fixtures named like keys are keys)" guard-secrets.sh "$(read_ test/fixtures/id_rsa)"
echo "-- guard-secrets: guardrails.secretPaths (absent = defaults, [] = none, list = literal)"
cfg '.guardrails.secretPaths=[]'
expect 0 "secretPaths []: Read .env allowed"                     guard-secrets.sh "$(read_ .env)"
expect 0 "secretPaths []: Read secrets/k.pem allowed"            guard-secrets.sh "$(read_ secrets/k.pem)"
expect 2 "secretPaths []: ~/.ssh still denied (home list fixed)" guard-secrets.sh "$(bash_ 'cat ~/.ssh/id_rsa')"
expect 2 "secretPaths []: token env var still denied"            guard-secrets.sh "$(bash_ 'GH_TOKEN=abc curl https://api.github.com')"
cfg '.guardrails.secretPaths=["vault/**"]'
expect 0 "secretPaths list: Read .env allowed (replaces defaults)" guard-secrets.sh "$(read_ .env)"
expect 2 "secretPaths list: Read vault/token denied"             guard-secrets.sh "$(read_ vault/token)"
expect 2 "secretPaths list: Read vault/token.example denied (configured lists have no exemption)" guard-secrets.sh "$(read_ vault/token.example)"
cfg '.guardrails.secretPaths=[".env.*"]'
expect 2 "secretPaths list: .env.example denied when the list says .env.*" guard-secrets.sh "$(read_ .env.example)"
cfg 'del(.guardrails.secretPaths)'
expect 2 "secretPaths absent: defaults back (Read .env denied)"  guard-secrets.sh "$(read_ .env)"
expect 0 "secretPaths absent: .env.example exempt again"          guard-secrets.sh "$(read_ .env.example)"

echo "-- guard-protected-paths: nothing protected by default except the release markers"
expect 0 "Edit workflow allowed"                  guard-protected-paths.sh "$(edit .github/workflows/ci.yml)"
expect 0 "Edit lockfile allowed"                  guard-protected-paths.sh "$(edit package-lock.json)"
expect 0 "Edit CODEOWNERS allowed"                guard-protected-paths.sh "$(edit CODEOWNERS)"
expect 0 "Edit .claude/settings.json allowed"     guard-protected-paths.sh "$(edit .claude/settings.json)"
expect 0 "Edit sdlc.config.json allowed"          guard-protected-paths.sh "$(edit sdlc.config.json)"
expect 0 "Edit src/a.ts allowed"                  guard-protected-paths.sh "$(edit src/a.ts)"
expect 0 "Bash rm sdlc.config.json allowed"       guard-protected-paths.sh "$(bash_ 'rm sdlc.config.json')"
expect 0 "Bash redirect into CODEOWNERS allowed"  guard-protected-paths.sh "$(bash_ 'echo x > CODEOWNERS')"
expect 0 "Bash sed -i on workflow allowed"        guard-protected-paths.sh "$(bash_ 'sed -i s/a/b/ .github/workflows/ci.yml')"
expect 2 "Bash touch of the unlock marker denied" guard-protected-paths.sh "$(bash_ 'touch .sdlc/UNLOCK_PROTECTED')"
expect 2 "Write release marker denied"            guard-protected-paths.sh "$(write_ ".sdlc/release/AUTHORIZED-$sha")"
expect 2 "Bash redirect into the release dir denied" guard-protected-paths.sh "$(bash_ "echo x > .sdlc/release/AUTHORIZED-$sha")"
echo "-- guard-protected-paths: guardrails.protectedPaths"
cfg '.guardrails.protectedPaths=["docs/adr/**"]'
expect 2 "protectedPaths list: ADR edit denied"                  guard-protected-paths.sh "$(edit docs/adr/0001-x.md)"
expect 2 "protectedPaths list: sed -i on an ADR denied"          guard-protected-paths.sh "$(bash_ 'sed -i s/a/b/ docs/adr/0001-x.md')"
expect 0 "protectedPaths list: cat of an ADR allowed"            guard-protected-paths.sh "$(bash_ 'cat docs/adr/0001-x.md')"
expect 0 "protectedPaths list: workflow edit still allowed"      guard-protected-paths.sh "$(edit .github/workflows/ci.yml)"
touch "$proj/.sdlc/UNLOCK_PROTECTED"
expect 0 "human unlock marker allows the configured path"        guard-protected-paths.sh "$(edit docs/adr/0001-x.md)"
expect 2 "human unlock marker never unlocks the release markers" guard-protected-paths.sh "$(write_ ".sdlc/release/AUTHORIZED-$sha")"
expect 2 "human unlock marker never unlocks itself"              guard-protected-paths.sh "$(bash_ 'rm .sdlc/UNLOCK_PROTECTED')"
rm "$proj/.sdlc/UNLOCK_PROTECTED"
cfg '.guardrails.protectedPaths=[]'
expect 0 "protectedPaths []: ADR edit allowed"                   guard-protected-paths.sh "$(edit docs/adr/0001-x.md)"
expect 2 "protectedPaths []: unlock marker still protected"      guard-protected-paths.sh "$(bash_ 'touch .sdlc/UNLOCK_PROTECTED')"
expect 2 "protectedPaths []: release marker still protected"     guard-protected-paths.sh "$(write_ ".sdlc/release/AUTHORIZED-$sha")"
cfg 'del(.guardrails.protectedPaths)'

echo "-- routine development passes every hook with no marker file"
routine=(
  "$(edit src/a.ts)" "$(edit src/a.test.ts)" "$(write_ src/__tests__/b.js)" "$(edit package-lock.json)" "$(edit .github/workflows/ci.yml)"
  "$(bash_ 'sed -i s/a/b/ src/a.ts')" "$(bash_ 'echo x > src/a.test.ts')" "$(bash_ 'npm install left-pad')" "$(bash_ 'pnpm install')"
  "$(bash_ 'bash scripts/generate.sh')" "$(bash_ 'python3 codegen.py')" "$(bash_ 'git add -A && git commit -m wip')" "$(bash_ 'git push origin feature/x')"
  "$(bash_ 'bash scripts/deploy.sh staging')" "$(bash_ 'npm test 2>&1 | tail -n 20')" "$(ps_ 'Set-Content -Path src/a.ts -Value x')"
)
for hook in "$H"/*.sh; do
  for inp in "${routine[@]}"; do
    run_hook "$hook" "$inp"
    [ "$HOOK_EXIT" = 0 ] && [ -z "$HOOK_ERR" ] || _fail "${hook##*/} blocks routine work" "$(jq -r '.tool_name + " " + (.tool_input.command // .tool_input.file_path)' <<<"$inp"): exit $HOOK_EXIT ${HOOK_ERR:0:160}"
  done
  _ok "${hook##*/} lets routine development through (${#routine[@]} inputs)"
done

echo "-- guard-verifier-readonly: file tools only"
expect 2 "verifier Edit denied"                   guard-verifier-readonly.sh "$(agent ai-sdlc:sdlc-verifier "$(edit src/a.ts)")"
expect 2 "verifier (bare name) Edit denied"       guard-verifier-readonly.sh "$(agent sdlc-verifier "$(edit src/a.ts)")"
expect 2 "auditor Write denied"                   guard-verifier-readonly.sh "$(agent ai-sdlc:sdlc-security-auditor "$(write_ x)")"
[[ "$HOOK_ERR" =~ read-only ]] && _ok "reason says the agent is read-only" || _fail "reason" "$HOOK_ERR"
expect 0 "verifier may run the test runner directly" guard-verifier-readonly.sh "$(agent ai-sdlc:sdlc-verifier "$(bash_ 'npm test -- --reporter=dot 2>&1 | tail -n 40')")"
expect 0 "verifier may run the configured verify command" guard-verifier-readonly.sh "$(agent ai-sdlc:sdlc-verifier "$(bash_ 'bash verify-mock.sh')")"
expect 0 "verifier may run the isolation helper"  guard-verifier-readonly.sh "$(agent ai-sdlc:sdlc-verifier "$(bash_ 'bash ${CLAUDE_PLUGIN_ROOT}/scripts/verify/run-isolated.sh')")"
expect 0 "verifier shell is not restricted (redirect)" guard-verifier-readonly.sh "$(agent ai-sdlc:sdlc-verifier "$(bash_ 'git log > result.txt')")"
expect 0 "verifier shell is not restricted (git commit)" guard-verifier-readonly.sh "$(agent ai-sdlc:sdlc-verifier "$(bash_ 'git add -A && git commit -m fix')")"
expect 0 "auditor shell is not restricted"        guard-verifier-readonly.sh "$(agent ai-sdlc:sdlc-security-auditor "$(bash_ 'sed -i s/a/b/ src/a.ts')")"
expect 0 "other agents are not restricted"        guard-verifier-readonly.sh "$(agent Explore "$(edit src/a.ts)")"
expect 0 "main thread is not restricted"          guard-verifier-readonly.sh "$(edit src/a.ts)"

echo "-- gate-production: configured patterns"
expect 2 "git push main denied without authorisation" gate-production.sh "$(bash_ 'git push origin main')"
[[ "$HOOK_ERR" =~ sdlc-ship ]] && _ok "reason points at /ai-sdlc:sdlc-ship" || _fail "reason" "$HOOK_ERR"
expect 2 "az pipelines run denied"                gate-production.sh "$(bash_ 'az pipelines run --name deploy')"
expect 2 "kubectl apply denied"                   gate-production.sh "$(bash_ 'kubectl apply -f k8s/')"
expect 2 "chained deploy denied"                  gate-production.sh "$(bash_ 'npm test && git push origin main')"
expect 0 "git push feature branch allowed"        gate-production.sh "$(bash_ 'git push origin feature/x')"
expect 0 "git status allowed"                     gate-production.sh "$(bash_ 'git status')"
expect 0 "helm upgrade allowed (not configured)"  gate-production.sh "$(bash_ 'helm upgrade app ./chart')"
mkdir -p "$proj/.sdlc/release"
marker() {  # marker <expires-epoch> [commit] : a complete authorisation file for $sha
  printf 'authorised_by=human\nauthorised_at=%s\nexpires=%s\nexpires_at=later\ncommit=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:-$sha}" >"$proj/.sdlc/release/AUTHORIZED-$sha"
}
marker "$(( $(date +%s) + 7200 ))"
expect 0 "git push main allowed with fresh authorisation" gate-production.sh "$(bash_ 'git push origin main')"
marker "$(( $(date +%s) - 60 ))"
expect 2 "expired authorisation denies"           gate-production.sh "$(bash_ 'git push origin main')"
[[ "$HOOK_ERR" =~ expire ]] && _ok "reason says expired" || _fail "reason" "$HOOK_ERR"
printf 'authorised_by=human\nexpires=%s\n' "$(( $(date +%s) + 7200 ))" >"$proj/.sdlc/release/AUTHORIZED-$sha"
expect 2 "authorisation without a commit field denies (release-authz.sh has every malformed case)" gate-production.sh "$(bash_ 'git push origin main')"
rm "$proj/.sdlc/release/AUTHORIZED-$sha"
printf 'authorised_by=human\nauthorised_at=now\nexpires=%s\ncommit=0000000000000000000000000000000000000000\n' "$(( $(date +%s) + 7200 ))" >"$proj/.sdlc/release/AUTHORIZED-0000000000000000000000000000000000000000"
expect 2 "authorisation for another commit denies" gate-production.sh "$(bash_ 'git push origin main')"
echo "-- gate-production: no built-in patterns"
cfg '.environments.prod.deployCommandPatterns=[]'
expect 0 "patterns []: git push main not gated"                  gate-production.sh "$(bash_ 'git push origin main')"
cfg 'del(.environments.prod.deployCommandPatterns)'
expect 0 "patterns absent: git push main not gated"              gate-production.sh "$(bash_ 'git push origin main')"
expect 0 "patterns absent: kubectl apply not gated"              gate-production.sh "$(bash_ 'kubectl apply -f k8s/')"
cfg 'del(.environments)'
expect 0 "no environments at all: nothing gated"                 gate-production.sh "$(bash_ 'git push origin main')"
cfg '.environments={prod:{gate:"human",deployCommandPatterns:["make deploy*"]}}'
expect 2 "patterns list: make deploy denied"                     gate-production.sh "$(bash_ 'make deploy ENV=production')"
expect 0 "patterns list: git push main not listed, allowed"      gate-production.sh "$(bash_ 'git push origin main')"
cfg '.environments={prod:{gate:"human",deployCommandPatterns:["git push * main","az pipelines run *","kubectl apply *"]}}'

echo "-- fail closed"
run_hook "$H/guard-secrets.sh" 'not json'
assert_eq "2" "$HOOK_EXIT" "guard denies on malformed input"

eval_done
