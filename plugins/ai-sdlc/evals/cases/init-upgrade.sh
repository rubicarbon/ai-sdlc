#!/usr/bin/env bash
# Managed-file lifecycle across a plugin update: a template change is reported as
# template-changed run after run (never degrading to user-edited), --upgrade applies it
# without --force, and --only limits both upgrades and the creation of missing files.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
export SDLC_PLATFORM_MOCK=1 HOME="$EVAL_TMP/home"; mkdir -p "$HOME"

# a private copy of the plugin, so its templates can be edited like a plugin update would
PC="$EVAL_TMP/plugin"; rm -rf "$PC"; cp -r "$P" "$PC"
export CLAUDE_PLUGIN_ROOT="$PC"
RUN="$PC/scripts/init/run.sh"

repo="$EVAL_TMP/repo"; mkdir -p "$repo"
git -C "$repo" init -q -b main; git -C "$repo" config user.email e@x; git -C "$repo" config user.name e; git -C "$repo" config core.autocrlf false
git -C "$repo" remote add origin https://github.com/mock-org/mock-repo.git
printf '{"name":"x","scripts":{"test":"vitest run"}}\n' >"$repo/package.json"
git -C "$repo" add -A >/dev/null; git -C "$repo" commit -q -m init

status_of() { jq -r --arg p "$2" '.files[] | select(.path==$p) | .status' <<<"$1"; }

echo "-- init with template A"
out=$(bash "$RUN" --repo-dir "$repo" --platform github --tier 1 --yes 2>"$EVAL_TMP/err1"); rc=$?
assert_eq "0" "$rc" "init exits 0 ($(head -c 200 "$EVAL_TMP/err1"))"
assert_eq "installed" "$(status_of "$out" REVIEW.md)" "REVIEW.md installed"
assert_eq "REVIEW.md.tmpl" "$(jq -r '."REVIEW.md".template' "$repo/.sdlc/managed-files.json")" "manifest records REVIEW.md"
hashA=$(jq -r '."REVIEW.md".sha256' "$repo/.sdlc/managed-files.json")
sha_of() { sha256sum "$1" | cut -d' ' -f1; }
assert_eq "$hashA" "$(sha_of "$repo/REVIEW.md")" "recorded hash equals the installed file"

echo "-- the plugin's template moves on (template B)"
printf '\n## Added by template B\n\nNew rule.\n' >>"$PC/templates/REVIEW.md.tmpl"
out=$(bash "$RUN" --repo-dir "$repo" --yes 2>"$EVAL_TMP/err2"); rc=$?
assert_eq "0" "$rc" "plain re-run exits 0"
assert_eq "template-changed" "$(status_of "$out" REVIEW.md)" "re-run reports template-changed"
grep -q 'Added by template B' "$repo/REVIEW.md" && _fail "plain re-run must not apply the template" "" || _ok "file still has template A"
assert_eq "$hashA" "$(jq -r '."REVIEW.md".sha256' "$repo/.sdlc/managed-files.json")" "manifest keeps the template A record"
assert_match 'template-changed: REVIEW.md' "$(cat "$EVAL_TMP/err2")" "stderr names the pending file"
out=$(bash "$RUN" --repo-dir "$repo" --check 2>/dev/null); rc=$?
assert_eq "1" "$rc" "--check exits 1 while the template change is pending"
assert_eq "drift" "$(jq -r .result <<<"$out")" "--check result is drift"
assert_eq "REVIEW.md" "$(jq -r '.pending[] | select(.status=="template-changed") | .path' <<<"$out")" "--check lists REVIEW.md as pending"

echo "-- a second plain run still says template-changed (the old defect flipped it to user-edited)"
out=$(bash "$RUN" --repo-dir "$repo" --yes 2>/dev/null)
assert_eq "template-changed" "$(status_of "$out" REVIEW.md)" "still template-changed on the next run"
assert_eq "0" "$(jq '.user_edited | length' <<<"$out")" "nothing is reported user-edited"

echo "-- --upgrade applies it without --force"
out=$(bash "$RUN" --repo-dir "$repo" --upgrade --yes 2>/dev/null); rc=$?
assert_eq "0" "$rc" "--upgrade exits 0"
assert_eq "upgraded" "$(status_of "$out" REVIEW.md)" "REVIEW.md upgraded"
grep -q 'Added by template B' "$repo/REVIEW.md" && _ok "file now has template B" || _fail "upgrade did not apply template B" ""
assert_eq "$(sha_of "$repo/REVIEW.md")" "$(jq -r '."REVIEW.md".sha256' "$repo/.sdlc/managed-files.json")" "manifest records the upgraded hash"
out=$(bash "$RUN" --repo-dir "$repo" --yes 2>/dev/null)
assert_eq "already-initialised" "$(jq -r .result <<<"$out")" "next plain run is already-initialised"
assert_eq "0" "$(bash "$RUN" --repo-dir "$repo" --check >/dev/null 2>&1; echo $?)" "--check is clean after the upgrade"

echo "-- --only limits upgrades and the creation of missing files"
printf '\n## Added by template C\n' >>"$PC/templates/REVIEW.md.tmpl"
printf '\n## Domain template C\n' >>"$PC/templates/agents/domain.md.tmpl"
rm -f "$repo/docs/agents/issue-tracker.md"
out=$(bash "$RUN" --repo-dir "$repo" --upgrade --only REVIEW.md --yes 2>/dev/null); rc=$?
assert_eq "0" "$rc" "--upgrade --only exits 0"
assert_eq "upgraded" "$(status_of "$out" REVIEW.md)" "listed file upgraded"
grep -q 'Added by template C' "$repo/REVIEW.md" && _ok "REVIEW.md has template C" || _fail "REVIEW.md not upgraded" ""
assert_eq "template-changed" "$(status_of "$out" docs/agents/domain.md)" "unlisted template change stays pending"
grep -q 'Domain template C' "$repo/docs/agents/domain.md" && _fail "unlisted file must not be upgraded" "" || _ok "unlisted file untouched"
assert_eq "missing" "$(status_of "$out" docs/agents/issue-tracker.md)" "missing file not in --only is reported missing"
assert_no_file "$repo/docs/agents/issue-tracker.md" "missing file not in --only is not installed"
out=$(bash "$RUN" --repo-dir "$repo" --upgrade --yes 2>/dev/null)
assert_eq "upgraded" "$(status_of "$out" docs/agents/domain.md)" "--upgrade without --only upgrades the rest"
assert_eq "installed" "$(status_of "$out" docs/agents/issue-tracker.md)" "--upgrade without --only re-creates the missing file"
assert_file "$repo/docs/agents/issue-tracker.md" "missing file installed"
out=$(bash "$RUN" --repo-dir "$repo" --yes 2>/dev/null)
assert_eq "already-initialised" "$(jq -r .result <<<"$out")" "everything up to date again"

echo "-- obsolete plugin deny rules: reported on plain runs, pruned only by --upgrade"
S="$repo/.claude/settings.json"
obsolete='["Edit(sdlc.config.json)","Edit(.env.*)","Read(**/*.pem)","Read(**/id_rsa*)","Read(**/id_ed25519*)"]'
jq --argjson o "$obsolete" '.permissions.deny += $o + ["Bash(rm -rf *)"] | .model = "opus"' "$S" >"$S.tmp" && mv "$S.tmp" "$S"
legacy=$(jq -cS . "$S")
out=$(bash "$RUN" --repo-dir "$repo" --check 2>/dev/null); rc=$?
assert_eq "1" "$rc" "--check exits 1 while obsolete rules are present"
assert_eq "template-changed" "$(status_of "$out" .claude/settings.json)" "--check reports settings template-changed"
assert_eq "$legacy" "$(jq -cS . "$S")" "--check wrote nothing"
out=$(bash "$RUN" --repo-dir "$repo" --yes 2>"$EVAL_TMP/err-prune"); rc=$?
assert_eq "0" "$rc" "plain re-run exits 0"
assert_eq "template-changed" "$(status_of "$out" .claude/settings.json)" "plain re-run reports template-changed"
assert_eq "$legacy" "$(jq -cS . "$S")" "plain re-run does not prune"
assert_match 'template-changed: .claude/settings.json' "$(cat "$EVAL_TMP/err-prune")" "stderr names settings.json"
out=$(bash "$RUN" --repo-dir "$repo" --upgrade --only REVIEW.md --yes 2>/dev/null)
assert_eq "template-changed" "$(status_of "$out" .claude/settings.json)" "--upgrade --only another file leaves settings pending"
assert_eq "$legacy" "$(jq -cS . "$S")" "--upgrade --only another file does not prune"
bash "$RUN" --repo-dir "$repo" --upgrade --dry-run --yes >/dev/null 2>&1
assert_eq "$legacy" "$(jq -cS . "$S")" "--upgrade --dry-run writes nothing"
# expected result: the stable merge (legacy plus the current fragments) followed by the prune
frag_base="$EVAL_TMP/frag-base.json"; frag_gh="$EVAL_TMP/frag-gh.json"
bash "$PC/scripts/init/render.sh" "$PC/templates/settings.json.tmpl" --config "$repo/sdlc.config.json" --out "$frag_base"
bash "$PC/scripts/init/render.sh" "$PC/templates/settings.github.json.tmpl" --config "$repo/sdlc.config.json" --out "$frag_gh"
expected=$(bash "$PC/scripts/init/merge-settings.sh" "$S" "$frag_base" "$frag_gh" --dry-run | jq -cS --argjson o "$obsolete" '.permissions.deny -= $o')
out=$(bash "$RUN" --repo-dir "$repo" --upgrade --yes 2>"$EVAL_TMP/err-upgrade"); rc=$?
assert_eq "0" "$rc" "--upgrade exits 0"
assert_eq "merged" "$(status_of "$out" .claude/settings.json)" "--upgrade reports settings merged"
assert_eq "$expected" "$(jq -cS . "$S")" "result is the merge followed by the prune (user rule, order and model kept)"
assert_eq "0" "$(jq --argjson o "$obsolete" '[.permissions.deny[] | select(IN($o[]))] | length' "$S")" "obsolete rules removed"
assert_eq "true" "$(jq '.permissions.deny | index("Bash(rm -rf *)") != null and index("Read(.env)") != null and index("Edit(.env.local)") != null' "$S")" "user rule and current plugin rules kept"
assert_eq "opus" "$(jq -r .model "$S")" "other keys untouched"
assert_eq "5" "$(grep -c 'removed obsolete deny rule' "$EVAL_TMP/err-upgrade")" "stderr lists each removed rule"
assert_eq "$(jq -cS '[.permissions.deny[]?] | unique' "$frag_base" "$frag_gh" | jq -cs 'add | unique')" "$(jq -cS '.[".claude/settings.json"].rules' "$repo/.sdlc/managed-files.json")" "manifest records the rules this version rendered"
out=$(bash "$RUN" --repo-dir "$repo" --yes 2>/dev/null)
assert_eq "already-initialised" "$(jq -r .result <<<"$out")" "no obsolete rules left: plain run is already-initialised"
assert_eq "0" "$(bash "$RUN" --repo-dir "$repo" --check >/dev/null 2>&1; echo $?)" "--check clean after the prune"

echo "-- legacy production patterns in sdlc.config.json survive re-runs and upgrades"
jq '.environments.prod.deployCommandPatterns += ["kubectl apply *","helm upgrade *"]' "$repo/sdlc.config.json" >"$repo/c.tmp" && mv "$repo/c.tmp" "$repo/sdlc.config.json"
bash "$RUN" --repo-dir "$repo" --yes >/dev/null 2>&1
bash "$RUN" --repo-dir "$repo" --upgrade --yes >/dev/null 2>&1
assert_eq "true" "$(jq '.environments.prod.deployCommandPatterns | index("kubectl apply *") != null and index("helm upgrade *") != null' "$repo/sdlc.config.json")" "seeded patterns from an earlier version are kept (explicit configuration now)"

echo "-- a user edit on top of a pending template change is still the user's"
printf '\n## Ours\n' >>"$repo/REVIEW.md"
printf '\n## Added by template D\n' >>"$PC/templates/REVIEW.md.tmpl"
out=$(bash "$RUN" --repo-dir "$repo" --upgrade --yes 2>/dev/null)
assert_eq "user-edited" "$(status_of "$out" REVIEW.md)" "edited file reported user-edited"
grep -q '## Ours' "$repo/REVIEW.md" && _ok "--upgrade kept the user edit" || _fail "upgrade clobbered the user edit" ""
out=$(bash "$RUN" --repo-dir "$repo" --yes 2>/dev/null)
assert_eq "user-edited" "$(status_of "$out" REVIEW.md)" "still user-edited on the next run"

eval_done
