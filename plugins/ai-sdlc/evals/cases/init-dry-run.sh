#!/usr/bin/env bash
# /sdlc-init engine: github and azure footprints, idempotent re-run, drift detection,
# user-edit protection, existing CLAUDE.md preserved, settings merged without clobbering.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
RUN="$P/scripts/init/run.sh"
export SDLC_PLATFORM_MOCK=1 HOME="$EVAL_TMP/home"; mkdir -p "$HOME"   # no real CLIs, no real plugin cache

new_repo() {  # new_repo <dir> <remote>
  rm -rf "$1"; mkdir -p "$1"; git -C "$1" init -q -b main; git -C "$1" config user.email e@x; git -C "$1" config user.name e; git -C "$1" config core.autocrlf false
  git -C "$1" remote add origin "$2"
  printf '{"name":"x","scripts":{"test":"vitest run","verify":"npm run lint && vitest run"}}\n' >"$1/package.json"; : >"$1/tsconfig.json"
  git -C "$1" add -A >/dev/null; git -C "$1" commit -q -m init
}
tree_hash() { ( cd "$1" && find . -path ./.git -prune -o -type f -print | sort | while read -r f; do printf '%s ' "$f"; sha256sum "$f" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$f" | cut -d' ' -f1; done ) | sha256sum | cut -d' ' -f1; }

echo "-- github tier 1"
gh="$EVAL_TMP/gh"; new_repo "$gh" https://github.com/mock-org/mock-repo.git
h0=$(tree_hash "$gh")
out=$(bash "$RUN" --repo-dir "$gh" --platform github --tier 1 --yes --dry-run 2>/dev/null); rc=$?
assert_eq "0" "$rc" "--dry-run on a fresh repo exits 0"
assert_eq "$h0" "$(tree_hash "$gh")" "--dry-run on a fresh repo leaves the tree byte-identical"
assert_no_file "$gh/.sdlc" "--dry-run creates no artifacts directory"
assert_eq "missing" "$(jq -r '.files[] | select(.path==".sdlc/features/") | .status' <<<"$out")" "--dry-run reports an absent artifact directory as missing"
out=$(bash "$RUN" --repo-dir "$gh" --platform github --tier 1 --yes --check 2>/dev/null); rc=$?
assert_eq "1" "$rc" "--check on a fresh repo exits 1"
assert_eq "$h0" "$(tree_hash "$gh")" "--check on a fresh repo leaves the tree byte-identical"
out=$(bash "$RUN" --repo-dir "$gh" --platform github --tier 1 --yes 2>"$gh.err"); rc=$?
assert_eq "0" "$rc" "init github tier 1 exits 0 ($(head -c 300 "$gh.err"))"
assert_eq "init" "$(jq -r .result <<<"$out")" "result is init"
for f in sdlc.config.json CLAUDE.md CONTEXT.md REVIEW.md docs/agents/domain.md docs/agents/issue-tracker.md .claude/settings.json .sdlc/managed-files.json .sdlc/features/.gitkeep .sdlc/verify/.gitkeep docs/adr/.gitkeep; do assert_file "$gh/$f" "github: $f exists"; done
for d in .sdlc/features/ .sdlc/verify/ .sdlc/releases/ .sdlc/postmortems/ .sdlc/metrics/cost/ docs/adr/; do
  assert_eq "installed" "$(jq -r --arg p "$d" '.files[] | select(.path==$p) | .status' <<<"$out")" "artifact directory $d reported installed"
done
assert_no_file "$gh/.github/workflows/sdlc-pr-review.yml" "github tier 1: no CI files yet"
assert_eq "0" "$(bash "$P/scripts/config/validate.sh" "$gh/sdlc.config.json" --quiet; echo $?)" "github: config validates"
assert_eq "npm run verify" "$(jq -r .commands.verify "$gh/sdlc.config.json")" "verify command detected from package.json (verify script preferred)"
assert_eq "typescript" "$(jq -r .stack.language "$gh/sdlc.config.json")" "language detected"
assert_eq "mock-org" "$(jq -r .repo.owner "$gh/sdlc.config.json")" "owner from remote"
assert_eq "null" "$(jq -c '.guardrails' "$gh/sdlc.config.json")" "init writes no guardrails block (no ticket enforcement at any tier)"
assert_eq '["git push * main"]' "$(jq -c '.environments.prod.deployCommandPatterns' "$gh/sdlc.config.json")" "production gate starts with a push to the default branch only"
assert_match 'GitHub \(via `sdlc-platform`\)' "$(head -n1 "$gh/docs/agents/issue-tracker.md")" "github tracker doc"
assert_eq "0" "$(grep -c '{{' "$gh/CLAUDE.md" "$gh/REVIEW.md" "$gh/docs/agents/issue-tracker.md" | awk -F: '{s+=$2} END{print s}')" "no unresolved markers in rendered files"
[ "$(wc -l <"$gh/CLAUDE.md")" -le 40 ] && _ok "CLAUDE.md under one page" || _fail "CLAUDE.md too long" ""
jq -e '.permissions.deny | (index("Read(.env)") != null) and (index("Read(~/.config/gh/**)") != null)' "$gh/.claude/settings.json" >/dev/null && _ok "settings carry secret deny rules incl. gh config" || _fail "settings deny rules" "$(cat "$gh/.claude/settings.json")"
assert_eq "$(jq -c '.permissions.deny + ["Read(~/.config/gh/**)"]' "$P/templates/settings.json.tmpl")" "$(jq -c .permissions.deny "$gh/.claude/settings.json")" "fresh settings deny list is the base template plus the platform rule, in order"
jq -e '.permissions.deny | (index("Edit(sdlc.config.json)") == null) and (index("Edit(.env.*)") == null) and (index("Read(**/*.pem)") == null) and (index("Edit(.env.local)") != null)' "$gh/.claude/settings.json" >/dev/null && _ok "no deny rule for sdlc.config.json, no wildcard .env edit rule, no blanket .pem rule" || _fail "obsolete deny rules rendered" "$(cat "$gh/.claude/settings.json")"
# the two layers agree: every default of guard-secrets.sh has a Read deny rule with the same text
# (.env.* is spelled out as explicit names so that .env.example stays readable in both layers)
hook_defaults=$(sed -n 's/^defaults=(\(.*\))$/\1/p' "$P/hooks/guard-secrets.sh" | tr -d '"')
for g in $hook_defaults; do
  case "$g" in .env.*) continue ;; esac
  jq -e --arg r "Read($g)" '.permissions.deny | index($r) != null' "$gh/.claude/settings.json" >/dev/null && _ok "deny rule matches hook default $g" || _fail "hook default without a deny rule" "$g"
done
jq -e '.permissions.deny | index("Read(.env.example)") == null and index("Edit(.env.example)") == null' "$gh/.claude/settings.json" >/dev/null && _ok "example env files are not denied by the permission layer either" || _fail ".env.example denied" ""
assert_eq "$(jq -c '.permissions.deny | unique' "$gh/.claude/settings.json")" "$(jq -c '.[".claude/settings.json"].rules' "$gh/.sdlc/managed-files.json")" "manifest records the rules the plugin installed"
jq -e '.enabledPlugins == null' "$gh/.claude/settings.json" >/dev/null && _ok "solo mode: no enabledPlugins" || _fail "solo enabledPlugins" ""
grep -qxF '.sdlc/UNLOCK_PROTECTED' "$gh/.gitignore" && grep -qxF '.sdlc/release/' "$gh/.gitignore" && _ok ".gitignore has the marker lines" || _fail ".gitignore" "$(cat "$gh/.gitignore")"
grep -qxF '.sdlc/FIX_MODE' "$gh/.gitignore" && _fail ".gitignore must not mention FIX_MODE" "" || _ok ".gitignore has no FIX_MODE or ACTIVE_TICKET lines"
assert_match 'sdlc-metrics-baseline' "$(jq -r '.next_steps | last' <<<"$out")" "next steps end with the metrics baseline"

echo "-- github re-run is idempotent"
( cd "$gh" && git add -A >/dev/null && git commit -q -m sdlc )
h1=$(tree_hash "$gh")
out2=$(bash "$RUN" --repo-dir "$gh" --platform github --tier 1 --yes 2>"$gh.err2"); rc=$?
assert_eq "0" "$rc" "re-run exits 0"
assert_eq "already-initialised" "$(jq -r .result <<<"$out2")" "re-run reports already initialised"
assert_match 'already initialised' "$(cat "$gh.err2")" "human-readable already-initialised note"
assert_eq "$h1" "$(tree_hash "$gh")" "re-run changed no file"
assert_eq "" "$(cd "$gh" && git status --porcelain)" "re-run leaves the working tree clean"
assert_eq "0" "$(bash "$RUN" --repo-dir "$gh" --check >/dev/null 2>&1; echo $?)" "--check exits 0 when clean"
assert_eq "$h1" "$(tree_hash "$gh")" "--check changed no file"
out=$(bash "$RUN" --repo-dir "$gh" --dry-run --yes 2>/dev/null); rc=$?
assert_eq "0" "$rc" "--dry-run on an initialised repo exits 0"
assert_eq "$h1" "$(tree_hash "$gh")" "--dry-run changed no file"
assert_eq "unchanged" "$(jq -r '.files[] | select(.path==".sdlc/features/") | .status' <<<"$out")" "existing artifact directory reported unchanged"

echo "-- artifact directory drift"
rm -rf "$gh/.sdlc/releases"
out=$(bash "$RUN" --repo-dir "$gh" --check 2>/dev/null); rc=$?
assert_eq "1" "$rc" "--check exits 1 when an artifact directory is missing"
assert_eq ".sdlc/releases/" "$(jq -r '.pending[] | .path' <<<"$out")" "--check lists the missing directory as pending"
hd=$(tree_hash "$gh")
out=$(bash "$RUN" --repo-dir "$gh" --dry-run --yes 2>/dev/null)
assert_eq "missing" "$(jq -r '.files[] | select(.path==".sdlc/releases/") | .status' <<<"$out")" "--dry-run reports the directory missing"
assert_eq "$hd" "$(tree_hash "$gh")" "--dry-run does not create it"
out=$(bash "$RUN" --repo-dir "$gh" --yes 2>/dev/null); rc=$?
assert_eq "0" "$rc" "plain run exits 0"
assert_eq "installed" "$(jq -r '.files[] | select(.path==".sdlc/releases/") | .status' <<<"$out")" "plain run re-creates the directory"
assert_file "$gh/.sdlc/releases/.gitkeep" "re-created directory has a .gitkeep placeholder"
rm -f "$gh/.sdlc/verify/.gitkeep"
out=$(bash "$RUN" --repo-dir "$gh" --check 2>/dev/null); rc=$?
assert_eq "0" "$rc" "a directory without .gitkeep is fine (--check clean)"
assert_eq "unchanged" "$(jq -r '.files[] | select(.path==".sdlc/verify/") | .status' <<<"$out")" "directory without .gitkeep reported unchanged"
: >"$gh/.sdlc/verify/.gitkeep"

echo "-- user edits are respected"
printf '\n## Local rule\n\nOurs.\n' >>"$gh/REVIEW.md"
out3=$(bash "$RUN" --repo-dir "$gh" --check 2>/dev/null); rc=$?
assert_eq "0" "$rc" "--check exits 0: an edited REVIEW.md is the user's business, not drift"
assert_match '"REVIEW.md","status":"user-edited"' "$(jq -c '.files[] | select(.path=="REVIEW.md")' <<<"$out3")" "check labels REVIEW.md user-edited"
bash "$RUN" --repo-dir "$gh" --upgrade --yes >/dev/null 2>&1
grep -q 'Local rule' "$gh/REVIEW.md" && _ok "--upgrade never overwrites a user-edited file" || _fail "upgrade clobbered user edit" ""
bash "$RUN" --repo-dir "$gh" --force --yes >/dev/null 2>&1
grep -q 'Local rule' "$gh/REVIEW.md" && _fail "--force should overwrite" "" || _ok "--force overwrites after explicit request"

echo "-- existing CLAUDE.md and settings are preserved"
ex="$EVAL_TMP/ex"; new_repo "$ex" https://github.com/mock-org/mock-repo.git
printf '# My project\n\nKeep this line.\n' >"$ex/CLAUDE.md"; mkdir -p "$ex/.claude"; printf '{"permissions":{"allow":["Bash(npm test)"],"deny":["Read(secrets/**)"]},"model":"opus"}\n' >"$ex/.claude/settings.json"
bash "$RUN" --repo-dir "$ex" --platform github --tier 0 --team team --yes >/dev/null 2>&1
grep -q 'Keep this line.' "$ex/CLAUDE.md" && grep -q 'ai-sdlc:begin' "$ex/CLAUDE.md" && _ok "existing CLAUDE.md kept, managed block appended" || _fail "CLAUDE.md merge" "$(cat "$ex/CLAUDE.md")"
jq -e '.model=="opus" and ((.permissions.allow|index("Bash(npm test)")) != null) and ((.permissions.deny|index("Read(.env)")) != null) and ((.permissions.deny|map(select(.=="Read(secrets/**)"))|length)==1)' "$ex/.claude/settings.json" >/dev/null && _ok "settings merged: existing keys kept, deny rules unioned without duplicates" || _fail "settings merge" "$(cat "$ex/.claude/settings.json")"
jq -e '.enabledPlugins["ai-sdlc@ai-sdlc-kit"]==true and .extraKnownMarketplaces["ai-sdlc-kit"].source.repo=="rubicarbon/ai-sdlc"' "$ex/.claude/settings.json" >/dev/null && _ok "team mode enables the plugins for teammates" || _fail "team enabledPlugins" ""
bash "$RUN" --repo-dir "$ex" --yes >/dev/null 2>&1
assert_eq "1" "$(grep -c 'ai-sdlc:begin' "$ex/CLAUDE.md")" "re-run does not duplicate the managed block"

echo "-- azure tier 1 and tier 3"
az="$EVAL_TMP/az"; new_repo "$az" https://dev.azure.com/mock-org/mock-proj/_git/mock-repo
out=$(bash "$RUN" --repo-dir "$az" --platform azure --tier 1 --yes 2>"$az.err"); rc=$?
assert_eq "0" "$rc" "init azure tier 1 exits 0 ($(head -c 300 "$az.err"))"
assert_match 'Azure DevOps \(via `sdlc-platform`\)' "$(head -n1 "$az/docs/agents/issue-tracker.md")" "azure tracker doc"
assert_eq "https://dev.azure.com/mock-org" "$(jq -r .azure.organization "$az/sdlc.config.json")" "azure org derived from remote"
assert_eq "mock-proj" "$(jq -r .azure.project "$az/sdlc.config.json")" "azure project derived from remote"
hz=$(tree_hash "$az")
out=$(bash "$RUN" --repo-dir "$az" --tier 3 --yes 2>"$az.err3"); rc=$?
assert_eq "2" "$rc" "re-tier to 3 without deploy commands exits 2"
assert_match -- '--deploy-staging CMD --deploy-production CMD' "$(cat "$az.err3")" "the error names both flags"
assert_match -- '--no-deploy' "$(cat "$az.err3")" "the error names --no-deploy"
assert_eq "$hz" "$(tree_hash "$az")" "the refused re-tier wrote nothing"
out=$(bash "$RUN" --repo-dir "$az" --tier 3 --yes --deploy-staging './deploy staging' --deploy-production './deploy production' 2>"$az.err3"); rc=$?
assert_eq "0" "$rc" "re-tier azure to 3 exits 0 ($(head -c 300 "$az.err3"))"
for f in .azuredevops/pipelines/sdlc-pr-review.yml .azuredevops/pipelines/sdlc-evals.yml .azuredevops/pipelines/sdlc-deploy.yml .azuredevops/pull_request_template.md .azuredevops/branch-policies.json; do assert_file "$az/$f" "azure tier 3: $f"; done
assert_match './deploy production' "$(cat "$az/.azuredevops/pipelines/sdlc-deploy.yml")" "azure deploy pipeline runs the configured production command"
assert_eq '["git push * main","./deploy production","./deploy production*"]' "$(jq -c '.environments.prod.deployCommandPatterns' "$az/sdlc.config.json")" "config patterns are the default-branch push plus the production command and its wildcard"
assert_no_file "$az/.github" "azure: no .github directory"
ghrefs=$(grep -rIwn 'gh' "$az" --exclude-dir=.git --exclude-dir=node_modules | grep -v 'github.com' || true)
assert_eq "" "$ghrefs" "azure footprint has zero references to gh"
assert_eq "0" "$(grep -rl '{{[A-Z_]*}}' "$az" --exclude-dir=.git | wc -l | tr -d ' ')" "azure: no unresolved markers anywhere"
assert_eq "null" "$(jq -c '.guardrails' "$az/sdlc.config.json")" "re-tier to 3 adds no guardrails block (tiers never enable ticket enforcement)"

echo "-- github tier 3 CI footprint"
gh3="$EVAL_TMP/gh3"; new_repo "$gh3" https://github.com/mock-org/mock-repo.git
out=$(bash "$RUN" --repo-dir "$gh3" --platform github --tier 3 --team team --yes 2>&1); rc=$?
assert_eq "2" "$rc" "tier 3 init without deploy commands exits 2"
assert_match 'commands.deployStaging, commands.deployProduction' "$out" "the error explains where the commands live"
assert_no_file "$gh3/sdlc.config.json" "the refused init wrote no config"
out=$(bash "$RUN" --repo-dir "$gh3" --platform github --tier 3 --team team --yes --deploy-staging 'make deploy ENV=staging' --deploy-production 'make deploy ENV=production' 2>&1 >/dev/null); rc=$?
assert_eq "0" "$rc" "tier 3 init with deploy commands exits 0 (${out:0:200})"
for f in .github/workflows/sdlc-pr-review.yml .github/workflows/sdlc-evals.yml .github/workflows/sdlc-cost-report.yml .github/workflows/sdlc-deploy.yml .github/PULL_REQUEST_TEMPLATE.md .github/CODEOWNERS; do assert_file "$gh3/$f" "github tier 3: $f"; done
assert_match '^\*[[:space:]]+@mock-org' "$(grep -E '^\*' "$gh3/.github/CODEOWNERS")" "CODEOWNERS defaults to the repo owner"
deploy_yml=$(cat "$gh3/.github/workflows/sdlc-deploy.yml")
assert_match 'make deploy ENV=staging' "$deploy_yml" "rendered deploy workflow runs the staging command"
assert_match 'make deploy ENV=production' "$deploy_yml" "rendered deploy workflow runs the production command"
assert_not_match 'scripts/deploy\.sh' "$deploy_yml" "rendered deploy workflow has no scripts/deploy.sh"
assert_eq "make deploy ENV=staging" "$(jq -r .commands.deployStaging "$gh3/sdlc.config.json")" "config stores commands.deployStaging"
assert_eq "make deploy ENV=production" "$(jq -r .commands.deployProduction "$gh3/sdlc.config.json")" "config stores commands.deployProduction"
assert_eq '["git push * main","make deploy ENV=production","make deploy ENV=production*"]' "$(jq -c '.environments.prod.deployCommandPatterns' "$gh3/sdlc.config.json")" "config patterns are the default-branch push plus the production command and its wildcard"
assert_eq "1" "$(jq '[.environments.prod.deployCommandPatterns[] | select(. == "make deploy ENV=production")] | length' "$gh3/sdlc.config.json")" "pattern added once"
out=$(bash "$RUN" --repo-dir "$gh3" --yes 2>/dev/null)
assert_eq "already-initialised" "$(jq -r .result <<<"$out")" "tier 3 re-run is idempotent"
assert_eq "1" "$(jq '[.environments.prod.deployCommandPatterns[] | select(. == "make deploy ENV=production")] | length' "$gh3/sdlc.config.json")" "re-run does not duplicate the pattern"

echo "-- tier 3 with --no-deploy"
nd="$EVAL_TMP/nodeploy"; new_repo "$nd" https://github.com/mock-org/mock-repo.git
out=$(bash "$RUN" --repo-dir "$nd" --platform github --tier 3 --yes --no-deploy 2>"$nd.err"); rc=$?
assert_eq "0" "$rc" "tier 3 init with --no-deploy exits 0 ($(head -c 200 "$nd.err"))"
assert_file "$nd/.github/workflows/sdlc-pr-review.yml" "--no-deploy still renders the review workflow"
assert_no_file "$nd/.github/workflows/sdlc-deploy.yml" "--no-deploy renders no deploy workflow"
assert_match 'Deployment automation was omitted' "$(jq -r '.next_steps | join("\n")' <<<"$out")" "--no-deploy: next_steps say deployment automation was omitted"
assert_eq "null" "$(jq -c '.commands.deployProduction' "$nd/sdlc.config.json")" "--no-deploy stores no deploy command"
out=$(bash "$RUN" --repo-dir "$nd" --yes 2>"$nd.err2"); rc=$?
assert_eq "0" "$rc" "plain re-run at tier 3 without deploy commands exits 0 (no error)"
assert_no_file "$nd/.github/workflows/sdlc-deploy.yml" "plain re-run skips the deploy template"
assert_match 'Deployment automation was omitted' "$(jq -r '.next_steps | join("\n")' <<<"$out")" "plain re-run: next_steps say deployment automation was omitted"
out=$(bash "$RUN" --repo-dir "$nd" --yes --deploy-staging 'npm run deploy:staging' --deploy-production 'npm run deploy:prod' 2>"$nd.err3"); rc=$?
assert_eq "0" "$rc" "re-run with the deploy flags exits 0 ($(head -c 200 "$nd.err3"))"
assert_file "$nd/.github/workflows/sdlc-deploy.yml" "re-run with the deploy flags renders the deploy workflow"
assert_match 'npm run deploy:prod' "$(cat "$nd/.github/workflows/sdlc-deploy.yml")" "rendered deploy workflow has the later-added command"
assert_eq "true" "$(jq '.environments.prod.deployCommandPatterns | index("npm run deploy:prod") != null' "$nd/sdlc.config.json")" "later-added production command is gated"

echo "-- environment names are canonicalised"
envs="$EVAL_TMP/envs"; new_repo "$envs" https://github.com/mock-org/mock-repo.git
out=$(bash "$RUN" --repo-dir "$envs" --platform github --tier 1 --yes --envs development,stage,production 2>&1 >/dev/null); rc=$?
assert_eq "0" "$rc" "--envs with long names exits 0 (${out:0:200})"
assert_eq '["dev","prod","staging"]' "$(jq -c '.environments | keys' "$envs/sdlc.config.json")" "environments stored under the canonical keys the hook reads"
assert_eq '["git push * main"]' "$(jq -c '.environments.prod.deployCommandPatterns' "$envs/sdlc.config.json")" "production patterns live under prod, not production"
bad_envs="$EVAL_TMP/badenvs"; new_repo "$bad_envs" https://github.com/mock-org/mock-repo.git
out=$(bash "$RUN" --repo-dir "$bad_envs" --platform github --tier 1 --yes --envs dev,qa 2>&1); rc=$?
assert_eq "2" "$rc" "an unknown environment name is a usage error"
assert_match 'dev, staging and prod' "$out" "the error names the accepted environments"
assert_no_file "$bad_envs/sdlc.config.json" "the refused init wrote no config"

echo "-- first-time adoption never prunes existing deny rules, whatever the flags"
for flag in --upgrade --force; do
  ad="$EVAL_TMP/adopt${flag//-/}"; new_repo "$ad" https://github.com/mock-org/mock-repo.git
  mkdir -p "$ad/.claude"; printf '{"permissions":{"deny":["Edit(sdlc.config.json)","Bash(rm -rf *)"]}}\n' >"$ad/.claude/settings.json"
  out=$(bash "$RUN" --repo-dir "$ad" --platform github --tier 1 --yes "$flag" 2>/dev/null); rc=$?
  assert_eq "0" "$rc" "first init with $flag exits 0"
  assert_eq "installed" "$(jq -r '.files[] | select(.path=="sdlc.config.json") | .status' <<<"$out")" "first init with $flag is an init"
  jq -e '.permissions.deny | index("Edit(sdlc.config.json)") != null and index("Bash(rm -rf *)") != null and index("Read(.env)") != null' "$ad/.claude/settings.json" >/dev/null && _ok "first init with $flag keeps every pre-existing rule and adds the plugin's" || _fail "first init with $flag pruned a pre-existing rule" "$(cat "$ad/.claude/settings.json")"
done

echo "-- errors"
mkdir -p "$EVAL_TMP/nogit"; out=$(bash "$RUN" --repo-dir "$EVAL_TMP/nogit" 2>&1); rc=$?; assert_eq "1" "$rc" "not a git repo exits 1"
none="$EVAL_TMP/none"; new_repo "$none" https://gitlab.com/o/r.git
out=$(bash "$RUN" --repo-dir "$none" --tier 1 --yes 2>&1); rc=$?
assert_eq "0" "$rc" "unknown remote defaults to platform none"
assert_eq "none" "$(jq -r .platform "$none/sdlc.config.json")" "platform none recorded"
assert_no_file "$none/docs/agents/issue-tracker.md" "platform none: no tracker doc (their local tracker applies)"
out=$(bash "$RUN" --repo-dir "$none" --tier 9 --yes 2>&1); rc=$?; assert_eq "2" "$rc" "bad tier is a usage error"


echo "-- review runner local: tier 3 footprints"
rl="$EVAL_TMP/runner-local"; new_repo "$rl" https://github.com/mock-org/mock-repo.git
out=$(bash "$RUN" --repo-dir "$rl" --platform github --tier 3 --yes --no-deploy --review-runner local 2>"$rl.err"); rc=$?
assert_eq "0" "$rc" "github tier 3 with --review-runner local exits 0 ($(head -c 200 "$rl.err"))"
assert_no_file "$rl/.github/workflows/sdlc-pr-review.yml" "local: no review workflow rendered"
assert_no_file "$rl/.github/workflows/sdlc-cost-report.yml" "local: no cost report workflow rendered"
assert_file "$rl/.github/workflows/sdlc-evals.yml" "local: the evals workflow is still rendered"
assert_eq "local" "$(jq -r .review.runner "$rl/sdlc.config.json")" "local: review.runner stored"
assert_eq "[]" "$(jq -c .github.requiredChecks "$rl/sdlc.config.json")" "local: github.requiredChecks is empty"
steps=$(jq -r '.next_steps | join("\n")' <<<"$out")
assert_not_match 'ANTHROPIC_API_KEY' "$steps" "local: next steps never mention the API key secret"
assert_match 'sdlc-review' "$steps" "local: next steps explain the local review"
assert_match 'production approval rule' "$steps" "local: the production approval step stays"
out=$(bash "$RUN" --repo-dir "$rl" --yes 2>/dev/null)
assert_eq "already-initialised" "$(jq -r .result <<<"$out")" "local: re-run is idempotent"
azl="$EVAL_TMP/runner-local-az"; new_repo "$azl" https://dev.azure.com/mock-org/mock-proj/_git/mock-repo
out=$(bash "$RUN" --repo-dir "$azl" --platform azure --tier 3 --yes --no-deploy --review-runner local 2>"$azl.err"); rc=$?
assert_eq "0" "$rc" "azure tier 3 with --review-runner local exits 0 ($(head -c 200 "$azl.err"))"
assert_no_file "$azl/.azuredevops/pipelines/sdlc-pr-review.yml" "azure local: no review pipeline rendered"
assert_file "$azl/.azuredevops/pipelines/sdlc-evals.yml" "azure local: evals pipeline rendered"
assert_eq "null" "$(jq -c '.azure.pipelineName' "$azl/sdlc.config.json")" "azure local: no pipelineName"
assert_eq "null" "$(jq -c '.policies | map(select(.kind=="build")) | first' "$azl/.azuredevops/branch-policies.json")" "azure local: branch policies carry no build requirement"
assert_eq "4" "$(jq -r '.policies | length' "$azl/.azuredevops/branch-policies.json")" "azure local: four policies"
out=$(bash "$RUN" --repo-dir "$EVAL_TMP/bogus-runner" --platform github --tier 1 --yes --review-runner bogus 2>&1); rc=$?
assert_eq "2" "$rc" "--review-runner bogus is a usage error"

echo "-- migration ci -> local on an initialised tier 3 repo"
mg="$EVAL_TMP/migrate"; new_repo "$mg" https://github.com/mock-org/mock-repo.git
bash "$RUN" --repo-dir "$mg" --platform github --tier 3 --yes --no-deploy >/dev/null 2>&1
( cd "$mg" && git add -A >/dev/null && git commit -q -m sdlc )
assert_file "$mg/.github/workflows/sdlc-pr-review.yml" "migration: ci repo has the review workflow"
h_before=$(tree_hash "$mg")
out=$(bash "$RUN" --repo-dir "$mg" --review-runner local --dry-run --yes 2>/dev/null); rc=$?
assert_eq "0" "$rc" "migration dry-run exits 0"
assert_eq "$h_before" "$(tree_hash "$mg")" "migration dry-run writes nothing"
assert_eq "retire-pending" "$(jq -r '.files[] | select(.path==".github/workflows/sdlc-pr-review.yml") | .status' <<<"$out")" "migration dry-run reports the review workflow as retire-pending"
assert_no_file "$mg/.sdlc/migrations.json" "migration dry-run writes no migrations file"
out=$(bash "$RUN" --repo-dir "$mg" --review-runner local --yes 2>"$mg.err"); rc=$?
assert_eq "0" "$rc" "migration to local exits 0 ($(head -c 200 "$mg.err"))"
assert_eq "retired" "$(jq -r '.files[] | select(.path==".github/workflows/sdlc-pr-review.yml") | .status' <<<"$out")" "untouched review workflow is retired"
assert_eq "retired" "$(jq -r '.files[] | select(.path==".github/workflows/sdlc-cost-report.yml") | .status' <<<"$out")" "untouched cost report workflow is retired"
assert_no_file "$mg/.github/workflows/sdlc-pr-review.yml" "retired review workflow is gone"
assert_no_file "$mg/.github/workflows/sdlc-cost-report.yml" "retired cost report is gone"
assert_file "$mg/.github/workflows/sdlc-evals.yml" "evals workflow stays"
assert_eq "local" "$(jq -r .review.runner "$mg/sdlc.config.json")" "config switched to local"
assert_eq "[]" "$(jq -c .github.requiredChecks "$mg/sdlc.config.json")" "sdlc-pr-review left github.requiredChecks"
assert_eq "null" "$(jq -c '.[".github/workflows/sdlc-pr-review.yml"]' "$mg/.sdlc/managed-files.json")" "manifest no longer records the retired file"
jq -e 'to_entries | all(.[]; (.key | test("^(\\.claude/settings\\.json|[^/]+|.+/.+)$")) and ((.value | type) == "object") and ((.value.template // "") | type == "string"))' "$mg/.sdlc/managed-files.json" >/dev/null && _ok "manifest holds managed paths only (no migration state inside)" || _fail "manifest shape" "$(cat "$mg/.sdlc/managed-files.json")"
assert_eq "pending" "$(jq -r '.["review-runner"].remote' "$mg/.sdlc/migrations.json")" "migrations.json records the pending remote reconciliation"
assert_eq "ci local" "$(jq -r '.["review-runner"] | "\(.from) \(.to)"' "$mg/.sdlc/migrations.json")" "migrations.json records from and to"
steps=$(jq -r '.next_steps | join("\n")' <<<"$out")
assert_match 'branch_protect_apply main' "$steps" "next steps name the remote reconciliation"
assert_match 'never pass with zero checks' "$steps" "next steps warn about zero checks on GitHub"
assert_not_match 'ANTHROPIC_API_KEY' "$steps" "next steps drop the API key"
out=$(bash "$RUN" --repo-dir "$mg" --yes 2>/dev/null)
assert_match 'branch_protect_apply main' "$(jq -r '.next_steps | join("\n")' <<<"$out")" "the remote step persists on the next plain run while pending"
assert_eq "0" "$(bash "$RUN" --repo-dir "$mg" --check >/dev/null 2>&1; echo $?)" "--check is clean after the migration"
jq '.["review-runner"].remote="done"' "$mg/.sdlc/migrations.json" >"$mg/m.json" && mv "$mg/m.json" "$mg/.sdlc/migrations.json"
out=$(bash "$RUN" --repo-dir "$mg" --yes 2>/dev/null)
assert_not_match 'branch_protect_apply main' "$(jq -r '.next_steps | join("\n")' <<<"$out")" "the remote step disappears once reconciled"
echo "-- migration keeps edited and unrecorded review files"
me="$EVAL_TMP/migrate-edited"; new_repo "$me" https://github.com/mock-org/mock-repo.git
bash "$RUN" --repo-dir "$me" --platform github --tier 3 --yes --no-deploy >/dev/null 2>&1
printf '\n# local tweak\n' >>"$me/.github/workflows/sdlc-pr-review.yml"
out=$(bash "$RUN" --repo-dir "$me" --review-runner local --yes 2>/dev/null); rc=$?
assert_eq "0" "$rc" "migration with an edited review workflow exits 0"
assert_eq "retire-pending" "$(jq -r '.files[] | select(.path==".github/workflows/sdlc-pr-review.yml") | .status' <<<"$out")" "edited review workflow is retire-pending"
assert_file "$me/.github/workflows/sdlc-pr-review.yml" "edited review workflow is kept"
assert_match 'Retired review files still present' "$(jq -r '.next_steps | join("\n")' <<<"$out")" "next steps list the kept file"
assert_eq "1" "$(bash "$RUN" --repo-dir "$me" --check >/dev/null 2>&1; echo $?)" "--check exits 1 while a retired file is still present"
out=$(bash "$RUN" --repo-dir "$me" --force --yes 2>/dev/null)
assert_no_file "$me/.github/workflows/sdlc-pr-review.yml" "--force removes the edited review workflow"
mu="$EVAL_TMP/migrate-unrecorded"; new_repo "$mu" https://github.com/mock-org/mock-repo.git
bash "$RUN" --repo-dir "$mu" --platform github --tier 3 --yes --no-deploy --review-runner local >/dev/null 2>&1
mkdir -p "$mu/.github/workflows"; printf 'name: mine\n' >"$mu/.github/workflows/sdlc-pr-review.yml"
out=$(bash "$RUN" --repo-dir "$mu" --yes 2>/dev/null)
assert_eq "retire-pending" "$(jq -r '.files[] | select(.path==".github/workflows/sdlc-pr-review.yml") | .status' <<<"$out")" "an unrecorded review workflow is retire-pending, never deleted"
assert_file "$mu/.github/workflows/sdlc-pr-review.yml" "unrecorded review workflow kept"
echo "-- migration with --only limits retirement, not the config change"
mo="$EVAL_TMP/migrate-only"; new_repo "$mo" https://github.com/mock-org/mock-repo.git
bash "$RUN" --repo-dir "$mo" --platform github --tier 3 --yes --no-deploy >/dev/null 2>&1
out=$(bash "$RUN" --repo-dir "$mo" --review-runner local --only REVIEW.md --yes 2>/dev/null)
assert_eq "local" "$(jq -r .review.runner "$mo/sdlc.config.json")" "--only: the config still switches"
assert_eq "retire-pending" "$(jq -r '.files[] | select(.path==".github/workflows/sdlc-pr-review.yml") | .status' <<<"$out")" "--only: the review workflow is not retired"
assert_file "$mo/.github/workflows/sdlc-pr-review.yml" "--only: the review workflow stays"
echo "-- switching back to ci"
out=$(bash "$RUN" --repo-dir "$mg" --review-runner ci --yes 2>/dev/null); rc=$?
assert_eq "0" "$rc" "switch back to ci exits 0"
assert_file "$mg/.github/workflows/sdlc-pr-review.yml" "ci: review workflow rendered again"
assert_eq '["sdlc-pr-review"]' "$(jq -c .github.requiredChecks "$mg/sdlc.config.json")" "ci: sdlc-pr-review is a required check again"
assert_match 'ANTHROPIC_API_KEY' "$(jq -r '.next_steps | join("\n")' <<<"$out")" "ci: the API key step is back"
echo "-- azure migration keeps a custom build requirement, refuses the review pipeline name"
ma="$EVAL_TMP/migrate-az"; new_repo "$ma" https://dev.azure.com/mock-org/mock-proj/_git/mock-repo
bash "$RUN" --repo-dir "$ma" --platform azure --tier 3 --yes --no-deploy >/dev/null 2>&1
jq '.azure.pipelineName="custom-ci"' "$ma/sdlc.config.json" >"$ma/c.json" && mv "$ma/c.json" "$ma/sdlc.config.json"
out=$(bash "$RUN" --repo-dir "$ma" --review-runner local --yes 2>/dev/null); rc=$?
assert_eq "0" "$rc" "azure migration with a custom pipeline exits 0"
assert_eq "custom-ci" "$(jq -r .azure.pipelineName "$ma/sdlc.config.json")" "custom pipelineName is kept"
assert_eq "custom-ci" "$(jq -r '.policies[] | select(.kind=="build") | .settings.pipelineName' "$ma/.azuredevops/branch-policies.json")" "branch policies keep the custom build requirement"
assert_no_file "$ma/.azuredevops/pipelines/sdlc-pr-review.yml" "azure migration retires the review pipeline"
jq '.azure.pipelineName="sdlc-pr-review"' "$ma/sdlc.config.json" >"$ma/c.json" && mv "$ma/c.json" "$ma/sdlc.config.json"
out=$(bash "$RUN" --repo-dir "$ma" --yes 2>&1); rc=$?
assert_eq "2" "$rc" "runner local with pipelineName sdlc-pr-review is refused"
assert_match 'names the review pipeline' "$out" "the refusal explains the conflict"

eval_done
