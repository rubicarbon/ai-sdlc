#!/usr/bin/env bash
# merge-settings.sh: arrays are a set union that keeps the existing order (duplicates already in
# the target collapse too), objects merge recursively, existing scalars win, the merge is
# idempotent across repeated runs, and --dry-run writes nothing.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
M="$P/scripts/init/merge-settings.sh"
render="$P/scripts/init/render.sh"
cfg="$P/templates/examples/sdlc.config.json"

# fragments: the plugin's own settings templates plus one hand-written fragment with a duplicate
frag1="$EVAL_TMP/f1.json"; frag2="$EVAL_TMP/f2.json"; frag3="$EVAL_TMP/f3.json"; frag4="$EVAL_TMP/f4.json"
bash "$render" "$P/templates/settings.json.tmpl" --config "$cfg" --out "$frag1"
bash "$render" "$P/templates/settings.azure.json.tmpl" --config "$cfg" --out "$frag2"
bash "$render" "$P/templates/settings.team.json.tmpl" --config "$cfg" --out "$frag3"
cat >"$frag4" <<'JSON'
{"permissions":{"deny":["Read(secrets/**)","Bash(rm -rf *)","Bash(rm -rf *)"],"allow":["Bash(pnpm test)"]},
 "model":"sonnet","nested":{"a":9,"b":2,"deep":{"x":[1,2]}},"env":{"FOO":"from-fragment"}}
JSON

target="$EVAL_TMP/.claude/settings.json"; mkdir -p "${target%/*}"
cat >"$target" <<'JSON'
{"permissions":{"deny":["Read(.env)","Read(.env)","Read(secrets/**)","Bash(git push --force *)"],"allow":["Bash(npm test)"]},
 "model":"opus","nested":{"a":1,"deep":{"x":[2,3],"y":true}}}
JSON
before=$(jq -cS . "$target")

echo "-- dry-run writes nothing"
out=$(bash "$M" "$target" "$frag1" "$frag2" "$frag3" "$frag4" --dry-run 2>&1); rc=$?
assert_eq "0" "$rc" "dry-run exits 0"
printf '%s' "$out" | jq -e . >/dev/null && _ok "dry-run prints the merged JSON" || _fail "dry-run output" "${out:0:200}"
assert_eq "$before" "$(jq -cS . "$target")" "dry-run leaves the target byte-identical"
assert_no_file "$EVAL_TMP/absent/settings.json" "dry-run precondition: no target yet"
bash "$M" "$EVAL_TMP/absent/settings.json" "$frag1" --dry-run >/dev/null 2>&1
assert_no_file "$EVAL_TMP/absent/settings.json" "dry-run does not create a missing target"

echo "-- three identical merges"
out1=$(bash "$M" "$target" "$frag1" "$frag2" "$frag3" "$frag4" 2>&1); rc=$?
assert_eq "0" "$rc" "merge 1 exits 0 (${out1:0:120})"
assert_eq "true" "$(printf '%s' "$out1" | jq -r .changed)" "merge 1 reports changed"
r1=$(jq -cS . "$target")
out2=$(bash "$M" "$target" "$frag1" "$frag2" "$frag3" "$frag4" 2>&1)
assert_eq "false" "$(printf '%s' "$out2" | jq -r .changed)" "merge 2 reports unchanged"
r2=$(jq -cS . "$target")
bash "$M" "$target" "$frag1" "$frag2" "$frag3" "$frag4" >/dev/null 2>&1
r3=$(jq -cS . "$target")
assert_eq "$r1" "$r2" "run 2 equals run 1 (jq -cS)"
assert_eq "$r1" "$r3" "run 3 equals run 1 (jq -cS)"
assert_eq "$(printf '%s' "$out" | jq -cS .)" "$r1" "dry-run output equals the written result"

echo "-- arrays"
assert_eq "1" "$(jq '.permissions.deny | group_by(.) | map(length) | max' "$target")" "every deny rule appears exactly once"
assert_eq "1" "$(jq '[.permissions.deny[] | select(. == "Read(.env)")] | length' "$target")" "pre-existing duplicate collapsed to one"
assert_eq "1" "$(jq '[.permissions.deny[] | select(. == "Bash(rm -rf *)")] | length' "$target")" "duplicate inside a fragment collapsed to one"
assert_eq '["Read(.env)","Read(secrets/**)","Bash(git push --force *)"]' "$(jq -c '.permissions.deny[0:3]' "$target")" "existing entries first, in their order"
assert_eq "Read(.env.local)" "$(jq -r '.permissions.deny[3]' "$target")" "new entries appended in fragment order"
assert_eq "true" "$(jq '.permissions.deny | index("Read(~/.azure/**)") != null and index("Bash(rm -rf *)") != null' "$target")" "new unique entries from every fragment present"
assert_eq '["Bash(npm test)","Bash(pnpm test)"]' "$(jq -c '.permissions.allow' "$target")" "allow list unioned"
assert_eq '[2,3,1]' "$(jq -c '.nested.deep.x' "$target")" "nested arrays unioned too (existing first)"

echo "-- objects and scalars"
assert_eq "opus" "$(jq -r .model "$target")" "existing scalar wins"
assert_eq "1" "$(jq -r .nested.a "$target")" "existing nested scalar wins"
assert_eq "2" "$(jq -r .nested.b "$target")" "new nested key added"
assert_eq "true" "$(jq -r .nested.deep.y "$target")" "deep existing key kept"
assert_eq "from-fragment" "$(jq -r .env.FOO "$target")" "new object added"
assert_eq "true" "$(jq -r '.enabledPlugins["ai-sdlc@ai-sdlc-kit"]' "$target")" "team fragment merged"
assert_eq "rubicarbon/ai-sdlc" "$(jq -r '.extraKnownMarketplaces["ai-sdlc-kit"].source.repo' "$target")" "marketplace fragment merged"

echo "-- errors"
printf '{broken' >"$EVAL_TMP/broken.json"
assert_exit 2 "invalid fragment is a usage error" -- bash "$M" "$target" "$EVAL_TMP/broken.json"
assert_exit 1 "invalid target is an error" -- bash "$M" "$EVAL_TMP/broken.json" "$frag1"
assert_exit 2 "no fragment is a usage error" -- bash "$M" "$target"
assert_eq "$r1" "$(jq -cS . "$target")" "failed runs left the target untouched"

eval_done
