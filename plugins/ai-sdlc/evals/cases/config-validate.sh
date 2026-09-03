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

printf 'not json' >"$EVAL_TMP/nj.json"
out=$(bash "$V" "$EVAL_TMP/nj.json" 2>&1); rc=$?
assert_eq "1" "$rc" "invalid JSON exits 1"
assert_match 'not valid JSON' "$out" "invalid JSON message"

# the schema published at the marketplace root is byte-identical to the plugin's copy
if cmp -s "$P/config/sdlc.config.schema.json" "$P/../../sdlc.config.schema.json"; then _ok "root schema matches the plugin schema"; else _fail "root schema drifted from plugins/ai-sdlc/config/sdlc.config.schema.json" ""; fi
jq -e '.["$schema"] == "http://json-schema.org/draft-07/schema#"' "$P/config/sdlc.config.schema.json" >/dev/null && _ok "schema declares draft-07" || _fail "schema draft" ""

eval_done
