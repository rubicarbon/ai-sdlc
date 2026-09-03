#!/usr/bin/env bash
# check-mattpocock.sh detects a missing/renamed/re-typed skill and an editable copy.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
chk="$P/scripts/reuse/check-mattpocock.sh"

# Build a fake installed plugin from the pinned manifest.
build_fake() {  # build_fake <dir>
  local d="$1"; mkdir -p "$d/.claude-plugin"
  local skills; skills=$(jq -c '[.skills | keys[] | "./skills/" + .]' "$P/scripts/reuse/mattpocock-manifest.json")
  jq -cn --argjson s "$skills" '{name:"mattpocock-skills",version:"1.2.3",skills:$s}' >"$d/.claude-plugin/plugin.json"
  while IFS=$'\t' read -r n t; do
    mkdir -p "$d/skills/$n"
    if [ "$t" = user ]; then printf -- '---\nname: %s\ndescription: x\ndisable-model-invocation: true\n---\nbody\n' "$n" >"$d/skills/$n/SKILL.md"
    else printf -- '---\nname: %s\ndescription: x\n---\nbody\n' "$n" >"$d/skills/$n/SKILL.md"; fi
  done < <(jq -r '.skills | to_entries[] | "\(.key)\t\(.value)"' "$P/scripts/reuse/mattpocock-manifest.json")
}

good="$EVAL_TMP/good"; build_fake "$good"
out=$(bash "$chk" --plugin-root "$good" --project "$EVAL_TMP/emptyproj" 2>&1); rc=$?
assert_eq "0" "$rc" "identical plugin: exit 0"
assert_match 'OK: routing table matches' "$out" "identical plugin: OK line"

renamed="$EVAL_TMP/renamed"; build_fake "$renamed"
mv "$renamed/skills/to-tickets" "$renamed/skills/to-issues"
jq -c '.skills |= map(if .=="./skills/to-tickets" then "./skills/to-issues" else . end)' "$renamed/.claude-plugin/plugin.json" >"$renamed/p.json" && mv "$renamed/p.json" "$renamed/.claude-plugin/plugin.json"
out=$(bash "$chk" --plugin-root "$renamed" --project "$EVAL_TMP/emptyproj" 2>&1); rc=$?
assert_eq "1" "$rc" "renamed skill: exit 1"
assert_match 'MISSING skill: to-tickets' "$out" "renamed skill reported missing"
assert_match 'new upstream skill not in the routing table: to-issues' "$out" "new name reported as added"
assert_match 'at least one skill that sdlc-loop routes to is gone' "$out" "routed skill loss called out"

retyped="$EVAL_TMP/retyped"; build_fake "$retyped"
printf -- '---\nname: tdd\ndescription: x\ndisable-model-invocation: true\n---\nbody\n' >"$retyped/skills/tdd/SKILL.md"
out=$(bash "$chk" --plugin-root "$retyped" --project "$EVAL_TMP/emptyproj" --json 2>&1); rc=$?
assert_eq "1" "$rc" "retyped skill: exit 1"
assert_match 'tdd: expected model-invoked, now user-invoked' "$(printf '%s' "$out" | jq -r '.retyped | join(" ")')" "retyped skill reported in JSON"
assert_eq "1" "$(printf '%s' "$out" | jq -r '.retyped | length')" "only the retyped skill is reported"

proj="$EVAL_TMP/proj"; mkdir -p "$proj/.claude/skills/tdd"; printf -- '---\nname: tdd\ndescription: x\n---\n' >"$proj/.claude/skills/tdd/SKILL.md"
out=$(bash "$chk" --plugin-root "$good" --project "$proj" 2>&1)
assert_match 'WARNING editable copy present .*\.claude/skills/tdd/SKILL\.md' "$out" "editable copy detected"

out=$(HOME="$EVAL_TMP/nohome" bash "$chk" --project "$EVAL_TMP/emptyproj" 2>&1); rc=$?
assert_eq "2" "$rc" "not installed: exit 2"
assert_match 'NOT installed' "$out" "not installed message"

eval_done
