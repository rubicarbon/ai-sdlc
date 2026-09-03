#!/usr/bin/env bash
# Every template renders from the example config with no marker left; examples carry no markers.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
cfg="$P/templates/examples/sdlc.config.json"
render="$P/scripts/init/render.sh"

for t in CLAUDE.md.tmpl CONTEXT.md.tmpl REVIEW.md.tmpl settings.json.tmpl settings.team.json.tmpl agents/issue-tracker-azure.md.tmpl agents/issue-tracker-github.md.tmpl; do
  out=$(bash "$render" "$P/templates/$t" --config "$cfg" --var REVIEW_NIT_CAP=5 2>&1); rc=$?
  assert_eq "0" "$rc" "$t renders (${out:0:120})"
  assert_not_match '\{\{' "$out" "$t has no unresolved markers"
done
out=$(bash "$render" "$P/templates/CLAUDE.md.tmpl" --config "$cfg" 2>&1)
assert_match 'pnpm verify' "$out" "CLAUDE.md carries the verify command"
lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
[ "$lines" -le 40 ] && _ok "CLAUDE.md stays under one page ($lines lines)" || _fail "CLAUDE.md too long" "$lines lines"

# settings fragments are valid JSON after rendering
out=$(bash "$render" "$P/templates/settings.json.tmpl" --config "$cfg"); printf '%s' "$out" | jq -e . >/dev/null && _ok "settings.json.tmpl is valid JSON" || _fail "settings.json.tmpl invalid JSON" "$out"
out=$(bash "$render" "$P/templates/settings.team.json.tmpl" --config "$cfg"); printf '%s' "$out" | jq -e '.enabledPlugins["ai-sdlc@ai-sdlc-kit"]==true' >/dev/null && _ok "team settings enable the plugin" || _fail "team settings" "$out"

# artifact templates: their markers are supplied by the commands, not the config; check they list them
out=$(bash "$render" "$P/templates/artifacts/release.md.tmpl" --config "$cfg" 2>&1); rc=$?
assert_eq "1" "$rc" "release template without --var fails loudly"
assert_match 'unresolved markers .*RELEASE_VERSION' "$out" "release template names the missing markers"
out=$(bash "$render" "$P/templates/artifacts/adr.md.tmpl" --config "$cfg" --var "ADR_TITLE=Use X" --var "ADR_DECISION=Because Y." 2>&1)
assert_eq "# Use X" "$(printf '%s\n' "$out" | head -n1)" "adr template renders with --var"

# branch templates render with the adapter's variables
out=$(bash "$render" "$P/templates/github/branch-protection.json" --config "$cfg" --var REVIEW_REQUIRED_APPROVALS=1 2>&1); printf '%s' "$out" | jq -e '.required_status_checks.contexts==["sdlc-pr-review"]' >/dev/null && _ok "branch-protection.json renders checks from config" || _fail "branch-protection.json" "$out"
out=$(bash "$render" "$P/templates/azure/branch-policies.json" --config "$cfg" --var AZURE_PIPELINE_NAME=sdlc-pr-review 2>&1); printf '%s' "$out" | jq -e '.policies[1].settings.requiredReviewerIds==["lead@contoso.com"]' >/dev/null && _ok "branch-policies.json renders reviewers from config" || _fail "branch-policies.json" "$out"

# filled examples contain no markers and no placeholders
bad=$(grep -rlE '\{\{|TODO|TBD|FIXME' "$P/templates/examples" || true)
assert_eq "" "$bad" "examples contain no markers or placeholders"
assert_file "$P/templates/examples/CLAUDE.md" "example CLAUDE.md exists"
jq -e . "$P/templates/examples/sdlc.config.json" >/dev/null && _ok "example config is valid JSON" || _fail "example config" ""

# a template must never produce CR characters on Windows
out=$(bash "$render" "$P/templates/CONTEXT.md.tmpl" --config "$cfg" | tr -cd '\r' | wc -c | tr -d ' ')
assert_eq "0" "$out" "rendered output has no CR characters"

eval_done
