#!/usr/bin/env bash
# The jq schema validator accepts the example config and rejects the mistakes people make.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
V="$P/scripts/config/validate.sh"
ex="$P/templates/examples/sdlc.config.json"

out=$(bash "$V" "$ex" 2>&1); rc=$?
assert_eq "0" "$rc" "example config is valid ($out)"

bad() {  # bad <jq mutation> <expected error regex> <label>
  local f="$EVAL_TMP/bad.json" out rc
  jq "$1" "$ex" >"$f"
  out=$(bash "$V" "$f" 2>&1); rc=$?
  assert_eq "1" "$rc" "$3: exit 1"
  assert_match "$2" "$out" "$3: message"
}
bad '.tier=5'                          'tier: must be <= 3'                 'tier out of range'
bad '.tier=1.5'                        'tier: expected integer'             'non-integer tier'
bad '.platform="gitlab"'               'platform: must be one of'           'unknown platform'
bad '.bogus=1'                         'bogus: unknown key'                 'unknown top-level key'
bad 'del(.commands.verify)'            'commands.verify: required'          'missing verify command'
bad '.commands.verify=""'              'commands.verify: must be at least 1' 'empty verify command'
bad '.azure.organization="dev.azure.com/x"' 'azure.organization: must match' 'azure org without https'
bad '.environments.prod.gate="manual"' 'environments.prod.gate: must be one of' 'bad environment gate via $ref'
bad '.guardrails.protectedPaths=["a", 3]' 'protectedPaths\[1\]: expected string' 'array item type'
bad '.review.requiredApprovals=0'      'requiredApprovals: must be >= 1'    'minimum'
bad '.version=2'                       'version: must be 1'                 'const'

# every enum value validates (the enum test is scalar membership, not subsequence lookup)
good() {  # good <jq mutation> <label>
  local f="$EVAL_TMP/good.json" out rc
  jq "$1" "$ex" >"$f"
  out=$(bash "$V" "$f" 2>&1); rc=$?
  assert_eq "0" "$rc" "$2 validates (${out:0:120})"
}
for p in github azure both none; do good ".platform=\"$p\"" "platform $p"; done
for m in solo team; do good ".team.mode=\"$m\"" "team.mode $m"; done
for g in none auto human; do good ".environments.prod.gate=\"$g\"" "environments.prod.gate $g"; done
for r in plugin editable absent; do good ".reuse.mattpocockSkills=\"$r\"" "reuse.mattpocockSkills $r"; done
good '.commands.verifySetup="pnpm install --frozen-lockfile"' "commands.verifySetup"
good '.commands.deployStaging="make deploy" | .commands.deployProduction="make deploy-prod"' "commands.deploy*"
good 'del(.commands.verifySetup) | del(.commands.deployStaging) | del(.commands.deployProduction)' "optional commands absent"
good '.guardrails.requireTicket=true | .guardrails.testGlobs=["**/*.test.ts"] | .guardrails.ticketFreePaths=["docs/**"] | .guardrails.verifyExtensions=["ts"]' "deprecated guardrails keys are still accepted (inert)"
good '.guardrails={}' "empty guardrails block"
good 'del(.guardrails)' "no guardrails block"
good '.guardrails.protectedPaths=[] | .guardrails.secretPaths=[]' "explicit empty guardrail lists"
good '.environments.prod.deployCommandPatterns=[]' "explicit empty production patterns"
good 'del(.environments.prod.deployCommandPatterns)' "absent production patterns"
bad '.commands.verifySetup=1'            'commands.verifySetup: expected string'  'verifySetup type'

# a freshly generated config validates
export SDLC_PLATFORM_MOCK=1 HOME="$EVAL_TMP/home"; mkdir -p "$HOME"
fresh="$EVAL_TMP/fresh"; mkdir -p "$fresh"
git -C "$fresh" init -q -b main; git -C "$fresh" config user.email e@x; git -C "$fresh" config user.name e
git -C "$fresh" remote add origin https://github.com/mock-org/mock-repo.git
printf '{"name":"x","scripts":{"test":"vitest run"}}\n' >"$fresh/package.json"
git -C "$fresh" add -A >/dev/null; git -C "$fresh" commit -q -m init
out=$(bash "$P/scripts/init/run.sh" --repo-dir "$fresh" --platform github --tier 1 --yes 2>&1 >/dev/null); rc=$?
assert_eq "0" "$rc" "run.sh generates a config (${out:0:200})"
out=$(bash "$V" "$fresh/sdlc.config.json" 2>&1); rc=$?
assert_eq "0" "$rc" "freshly generated config validates ($out)"
assert_eq "true" "$(jq -r '.["$schema"] | endswith("/sdlc.config.schema.json")' "$fresh/sdlc.config.json")" "generated config points at the published schema"

printf 'not json' >"$EVAL_TMP/nj.json"
out=$(bash "$V" "$EVAL_TMP/nj.json" 2>&1); rc=$?
assert_eq "1" "$rc" "invalid JSON exits 1"
assert_match 'not valid JSON' "$out" "invalid JSON message"

# the schema published at the marketplace root is byte-identical to the plugin's copy
if cmp -s "$P/config/sdlc.config.schema.json" "$P/../../sdlc.config.schema.json"; then _ok "root schema matches the plugin schema"; else _fail "root schema drifted from plugins/ai-sdlc/config/sdlc.config.schema.json" ""; fi
jq -e '.["$schema"] == "http://json-schema.org/draft-07/schema#"' "$P/config/sdlc.config.schema.json" >/dev/null && _ok "schema declares draft-07" || _fail "schema draft" ""

eval_done
