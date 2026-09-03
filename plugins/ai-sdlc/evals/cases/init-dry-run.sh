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
out=$(bash "$RUN" --repo-dir "$gh" --platform github --tier 1 --yes 2>"$gh.err"); rc=$?
assert_eq "0" "$rc" "init github tier 1 exits 0 ($(head -c 300 "$gh.err"))"
assert_eq "init" "$(jq -r .result <<<"$out")" "result is init"
for f in sdlc.config.json CLAUDE.md CONTEXT.md REVIEW.md docs/agents/domain.md docs/agents/issue-tracker.md .claude/settings.json .sdlc/managed-files.json .sdlc/features/.gitkeep .sdlc/verify/.gitkeep docs/adr/.gitkeep; do assert_file "$gh/$f" "github: $f exists"; done
assert_no_file "$gh/.github/workflows/sdlc-pr-review.yml" "github tier 1: no CI files yet"
assert_eq "0" "$(bash "$P/scripts/config/validate.sh" "$gh/sdlc.config.json" --quiet; echo $?)" "github: config validates"
assert_eq "npm run verify" "$(jq -r .commands.verify "$gh/sdlc.config.json")" "verify command detected from package.json (verify script preferred)"
assert_eq "typescript" "$(jq -r .stack.language "$gh/sdlc.config.json")" "language detected"
assert_eq "mock-org" "$(jq -r .repo.owner "$gh/sdlc.config.json")" "owner from remote"
assert_eq "false" "$(jq -r .guardrails.requireTicket "$gh/sdlc.config.json")" "tier 1 does not require tickets"
assert_match 'GitHub \(via `sdlc-platform`\)' "$(head -n1 "$gh/docs/agents/issue-tracker.md")" "github tracker doc"
assert_eq "0" "$(grep -c '{{' "$gh/CLAUDE.md" "$gh/REVIEW.md" "$gh/docs/agents/issue-tracker.md" | awk -F: '{s+=$2} END{print s}')" "no unresolved markers in rendered files"
[ "$(wc -l <"$gh/CLAUDE.md")" -le 40 ] && _ok "CLAUDE.md under one page" || _fail "CLAUDE.md too long" ""
jq -e '.permissions.deny | (index("Read(.env)") != null) and (index("Read(~/.config/gh/**)") != null)' "$gh/.claude/settings.json" >/dev/null && _ok "settings carry secret deny rules incl. gh config" || _fail "settings deny rules" "$(cat "$gh/.claude/settings.json")"
jq -e '.enabledPlugins == null' "$gh/.claude/settings.json" >/dev/null && _ok "solo mode: no enabledPlugins" || _fail "solo enabledPlugins" ""
grep -qxF '.sdlc/FIX_MODE' "$gh/.gitignore" && _ok ".gitignore has the marker lines" || _fail ".gitignore" ""
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
jq -e '.enabledPlugins["ai-sdlc@ai-sdlc-kit"]==true and .extraKnownMarketplaces["ai-sdlc-kit"].source.repo=="gergely-somogyvari/ai-sdlc-kit"' "$ex/.claude/settings.json" >/dev/null && _ok "team mode enables the plugins for teammates" || _fail "team enabledPlugins" ""
bash "$RUN" --repo-dir "$ex" --yes >/dev/null 2>&1
assert_eq "1" "$(grep -c 'ai-sdlc:begin' "$ex/CLAUDE.md")" "re-run does not duplicate the managed block"

echo "-- azure tier 1 and tier 3"
az="$EVAL_TMP/az"; new_repo "$az" https://dev.azure.com/mock-org/mock-proj/_git/mock-repo
out=$(bash "$RUN" --repo-dir "$az" --platform azure --tier 1 --yes 2>"$az.err"); rc=$?
assert_eq "0" "$rc" "init azure tier 1 exits 0 ($(head -c 300 "$az.err"))"
assert_match 'Azure DevOps \(via `sdlc-platform`\)' "$(head -n1 "$az/docs/agents/issue-tracker.md")" "azure tracker doc"
assert_eq "https://dev.azure.com/mock-org" "$(jq -r .azure.organization "$az/sdlc.config.json")" "azure org derived from remote"
assert_eq "mock-proj" "$(jq -r .azure.project "$az/sdlc.config.json")" "azure project derived from remote"
out=$(bash "$RUN" --repo-dir "$az" --tier 3 --yes 2>"$az.err3"); rc=$?
assert_eq "0" "$rc" "re-tier azure to 3 exits 0 ($(head -c 300 "$az.err3"))"
for f in .azuredevops/pipelines/sdlc-pr-review.yml .azuredevops/pipelines/sdlc-evals.yml .azuredevops/pipelines/sdlc-deploy.yml .azuredevops/pull_request_template.md .azuredevops/branch-policies.json; do assert_file "$az/$f" "azure tier 3: $f"; done
assert_no_file "$az/.github" "azure: no .github directory"
ghrefs=$(grep -rIwn 'gh' "$az" --exclude-dir=.git --exclude-dir=node_modules | grep -v 'github.com' || true)
assert_eq "" "$ghrefs" "azure footprint has zero references to gh"
assert_eq "0" "$(grep -rl '{{[A-Z_]*}}' "$az" --exclude-dir=.git | wc -l | tr -d ' ')" "azure: no unresolved markers anywhere"
assert_eq "true" "$(jq -r .guardrails.requireTicket "$az/sdlc.config.json")" "tier 3 requires tickets"

echo "-- github tier 3 CI footprint"
gh3="$EVAL_TMP/gh3"; new_repo "$gh3" https://github.com/mock-org/mock-repo.git
bash "$RUN" --repo-dir "$gh3" --platform github --tier 3 --team team --yes >/dev/null 2>&1
for f in .github/workflows/sdlc-pr-review.yml .github/workflows/sdlc-evals.yml .github/workflows/sdlc-cost-report.yml .github/workflows/sdlc-deploy.yml .github/PULL_REQUEST_TEMPLATE.md .github/CODEOWNERS; do assert_file "$gh3/$f" "github tier 3: $f"; done
assert_match '^\*[[:space:]]+@mock-org' "$(grep -E '^\*' "$gh3/.github/CODEOWNERS")" "CODEOWNERS defaults to the repo owner"

echo "-- errors"
mkdir -p "$EVAL_TMP/nogit"; out=$(bash "$RUN" --repo-dir "$EVAL_TMP/nogit" 2>&1); rc=$?; assert_eq "1" "$rc" "not a git repo exits 1"
none="$EVAL_TMP/none"; new_repo "$none" https://gitlab.com/o/r.git
out=$(bash "$RUN" --repo-dir "$none" --tier 1 --yes 2>&1); rc=$?
assert_eq "0" "$rc" "unknown remote defaults to platform none"
assert_eq "none" "$(jq -r .platform "$none/sdlc.config.json")" "platform none recorded"
assert_no_file "$none/docs/agents/issue-tracker.md" "platform none: no tracker doc (their local tracker applies)"
out=$(bash "$RUN" --repo-dir "$none" --tier 9 --yes 2>&1); rc=$?; assert_eq "2" "$rc" "bad tier is a usage error"

eval_done
