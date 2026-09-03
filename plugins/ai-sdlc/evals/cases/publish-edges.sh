#!/usr/bin/env bash
# A spec plus tickets publish to Azure DevOps (and GitHub) with blocking edges intact,
# ids written back, and a second run creating nothing new.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"

for platform in azure github; do
  work="$EVAL_TMP/$platform"; mkdir -p "$work"; cp -r "$EVAL_ROOT/fixtures/feature-mock" "$work/feature"
  export SDLC_MOCK_STATE="$work/state"; mkdir -p "$SDLC_MOCK_STATE"
  ( cd "$work" && git init -q -b main . && git config core.autocrlf false && git remote add origin "$( [ $platform = github ] && echo https://github.com/mock-org/mock-repo.git || echo https://dev.azure.com/mock-org/mock-proj/_git/mock-repo )" )
  cat >"$work/sdlc.config.json" <<JSON
{"version":1,"platform":"$platform","tier":1,"repo":{"owner":"mock-org","name":"mock-repo","defaultBranch":"main"},
 "azure":{"organization":"https://dev.azure.com/mock-org","project":"mock-proj","repo":"mock-repo","workItemType":"User Story"},"artifacts":{"dir":".sdlc"}}
JSON
  out=$(cd "$work" && SDLC_PLATFORM_MOCK=1 bash "$P/scripts/publish/publish.sh" feature 2>"$work/err.txt"); rc=$?
  assert_eq "0" "$rc" "[$platform] publish.sh exits 0 ($(head -c 200 "$work/err.txt"))"
  assert_eq "4" "$(printf '%s' "$out" | jq -r .created)" "[$platform] spec + 3 tickets created"
  assert_eq "3" "$(printf '%s' "$out" | jq -r .linked)" "[$platform] 3 blocking edges applied (01->02, 01->03, 02->03)"
  m="$work/feature/publish-manifest.json"
  assert_eq "3" "$(jq '.tickets|length' "$m")" "[$platform] manifest lists 3 tickets"
  assert_eq "3" "$(jq '.links|length' "$m")" "[$platform] manifest lists 3 links"
  assert_match '^<!-- sdlc-publish: id=[0-9]+ url=https://' "$(head -n1 "$work/feature/spec.md")" "[$platform] spec has the write-back marker"
  assert_match '^<!-- sdlc-publish: id=[0-9]+ url=https://' "$(head -n1 "$work/feature/issues/03-opt-out.md")" "[$platform] ticket has the write-back marker"
  assert_eq "# 03: Per-account opt-out" "$(sed -n 2p "$work/feature/issues/03-opt-out.md")" "[$platform] ticket body preserved under the marker"
  if [ $platform = azure ]; then
    t1=$(jq -r '.tickets["01"].id' "$m"); t2=$(jq -r '.tickets["02"].id' "$m"); t3=$(jq -r '.tickets["03"].id' "$m"); s=$(jq -r '.spec.id' "$m")
    rel="$SDLC_MOCK_STATE/relations.log"
    assert_match "^$t1\|successor\|$t2\$" "$(grep -E "^$t1\|successor\|$t2\$" "$rel")" "[azure] native Successor link 01 -> 02"
    assert_match "^$t1\|successor\|$t3\$" "$(grep -E "^$t1\|successor\|$t3\$" "$rel")" "[azure] native Successor link 01 -> 03"
    assert_match "^$t2\|successor\|$t3\$" "$(grep -E "^$t2\|successor\|$t3\$" "$rel")" "[azure] native Successor link 02 -> 03"
    assert_eq "3" "$(grep -c "|parent|$s\$" "$rel")" "[azure] every ticket has the spec as Parent"
  else
    assert_eq "3" "$(wc -l <"$SDLC_MOCK_STATE/deps.log" | tr -d ' ')" "[github] three dependency API calls recorded"
  fi
  # second run: idempotent
  out2=$(cd "$work" && SDLC_PLATFORM_MOCK=1 bash "$P/scripts/publish/publish.sh" feature 2>/dev/null)
  assert_eq "0" "$(printf '%s' "$out2" | jq -r .created)" "[$platform] re-run creates nothing"
  assert_eq "4" "$(printf '%s' "$out2" | jq -r .skipped)" "[$platform] re-run skips all four items"
  assert_eq "1" "$(grep -c '^<!-- sdlc-publish' "$work/feature/spec.md")" "[$platform] marker not duplicated on re-run"
done

# dry run prints CLI commands and writes nothing
work="$EVAL_TMP/dry"; mkdir -p "$work"; cp -r "$EVAL_ROOT/fixtures/feature-mock" "$work/feature"
cp "$EVAL_TMP/azure/sdlc.config.json" "$work/sdlc.config.json"
out=$(cd "$work" && SDLC_MOCK_STATE="$work/state" bash "$P/scripts/publish/publish.sh" feature --platform azure --dry-run 2>/dev/null)
assert_match '^\+ az boards work-item create' "$(printf '%s\n' "$out" | grep -m1 '^+ az boards work-item create')" "dry-run lists the az commands"
assert_no_file "$work/feature/publish-manifest.json.tmp" "dry-run leaves no temp files"
assert_eq "# Spec: Nightly usage digest" "$(head -n1 "$work/feature/spec.md")" "dry-run does not write markers"

eval_done
