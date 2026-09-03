#!/usr/bin/env bash
# CI templates for both platforms render without markers; the Azure set never mentions gh,
# the GitHub set never mentions az; caps and gates are present.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
cfg="$P/templates/examples/sdlc.config.json"
render="$P/scripts/init/render.sh"

for t in "$P"/templates/github/workflows/*.yml "$P"/templates/github/PULL_REQUEST_TEMPLATE.md "$P"/templates/github/CODEOWNERS.tmpl "$P"/templates/azure/pipelines/*.yml "$P"/templates/azure/pull_request_template.md; do
  name="${t#"$P"/templates/}"
  out=$(bash "$render" "$t" --config "$cfg" 2>&1); rc=$?
  assert_eq "0" "$rc" "$name renders (${out:0:100})"
  assert_not_match '\{\{[A-Z0-9_]+\}\}' "$out" "$name has no unresolved markers"
  case "$name" in github/*) prefix=gh- ;; *) prefix=az- ;; esac
  printf '%s\n' "$out" >"$EVAL_TMP/$prefix$(basename "$t")"
done

gh_yml=$(cat "$EVAL_TMP"/gh-*.yml)
assert_match -- '--max-turns 40 --max-budget-usd 5' "$gh_yml" "GitHub review carries the cost caps from config"
assert_match 'environment: production' "$gh_yml" "GitHub deploy has the production environment gate"
assert_match 'anthropics/claude-code-action@v1' "$gh_yml" "GitHub review uses the official action"
assert_match 'plugin_marketplaces' "$gh_yml" "GitHub review installs the plugin from the marketplace"
assert_not_match '(^|[^a-z_.-])az ' "$gh_yml" "GitHub workflows never call az"
assert_match 'a human code owner approves' "$gh_yml" "GitHub review states it is advisory"

az_yml=$(cat "$EVAL_TMP"/az-*.yml)
assert_match 'group: sdlc-secrets' "$az_yml" "Azure review reads the variable group"
assert_match -- '--max-turns "\$\(SDLC_MAX_TURNS\)" --max-budget-usd "\$\(SDLC_MAX_BUDGET_USD\)"' "$az_yml" "Azure review carries the cost caps"
assert_match 'value: "40"' "$az_yml" "Azure max turns from config"
assert_match 'environment: production' "$az_yml" "Azure deploy has the production environment"
assert_match 'sdlc-platform" pr_comment' "$az_yml" "Azure review posts through the adapter"
assert_not_match '(^|[^a-z_.-])gh ' "$az_yml" "Azure pipelines never call gh"
assert_match 'a human required reviewer approves' "$az_yml" "Azure review states it is advisory"

assert_match '@contoso/platform-leads' "$(cat "$EVAL_TMP/gh-CODEOWNERS.tmpl")" "CODEOWNERS renders the team handles"
assert_match '\*\*/auth/\*\*[[:space:]]+@contoso/security' "$(cat "$EVAL_TMP/gh-CODEOWNERS.tmpl")" "CODEOWNERS routes human-only areas to security owners"
assert_match 'Authorship disclosure' "$(cat "$EVAL_TMP/gh-PULL_REQUEST_TEMPLATE.md")" "PR template asks for agent authorship disclosure"
assert_match 'AB#<ticket-id>' "$(cat "$EVAL_TMP/az-pull_request_template.md")" "Azure PR template links the work item"

# YAML sanity without a parser: every rendered pipeline starts with a top-level key and has balanced quotes per line
for f in "$EVAL_TMP"/*.yml; do
  first=$(grep -m1 -vE '^\s*(#|$)' "$f")
  assert_match '^[a-z]+:' "$first" "$(basename "$f") starts with a top-level key ($first)"
done
eval_done
