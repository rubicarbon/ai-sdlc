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
  assert_eq "$platform" "$(jq -r .platform "$m")" "[$platform] manifest records the platform"
  assert_match "platform=$platform -->\$" "$(head -n1 "$work/feature/spec.md")" "[$platform] spec marker names the platform"
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

tree_hash() { ( cd "$1" && find . -path ./.git -prune -o -type f -print | sort | while read -r f; do printf '%s ' "$f"; sha256sum "$f" | cut -d' ' -f1; done ) | sha256sum | cut -d' ' -f1; }

echo "-- dry run prints CLI commands and writes nothing"
# the work dir has no git remote (the enclosing repo's GitHub remote must not leak in), so the
# platform is explicit; mock state lives outside the hashed tree
work="$EVAL_TMP/dry"; mkdir -p "$work"; cp -r "$EVAL_ROOT/fixtures/feature-mock" "$work/feature"
cp "$EVAL_TMP/azure/sdlc.config.json" "$work/sdlc.config.json"
hd=$(tree_hash "$work")
out=$(cd "$work" && SDLC_MOCK_STATE="$EVAL_TMP/dry-state" bash "$P/scripts/publish/publish.sh" feature --platform azure --dry-run 2>"$EVAL_TMP/dry.err"); rc=$?
assert_eq "0" "$rc" "dry-run exits 0 ($(head -c 200 "$EVAL_TMP/dry.err"))"
assert_match '^\+ az boards work-item create' "$(printf '%s\n' "$out" | grep -m1 '^+ az boards work-item create')" "dry-run lists the az commands"
assert_eq "4" "$(printf '%s\n' "$out" | grep -c '^+ az boards work-item create')" "dry-run lists one az create per item"
assert_not_match '^\+ gh ' "$out" "dry-run with --platform azure runs no gh command"
assert_eq "$hd" "$(tree_hash "$work")" "dry-run leaves the work dir byte-identical (feature dir + config)"
assert_no_file "$work/feature/publish-manifest.json" "dry-run writes no manifest"
assert_no_file "$work/feature/publish-manifest.json.tmp" "dry-run leaves no temp files"
assert_eq "" "$(ls "$work/feature" | grep -v -e '^spec.md$' -e '^issues$')" "dry-run adds nothing to the feature dir"
assert_eq "# Spec: Nightly usage digest" "$(head -n1 "$work/feature/spec.md")" "dry-run does not write markers"

echo "-- explicit --platform wins over the git remote"
ov="$EVAL_TMP/override"; mkdir -p "$ov"; cp -r "$EVAL_ROOT/fixtures/feature-mock" "$ov/feature"
( cd "$ov" && git init -q -b main . && git config core.autocrlf false && git remote add origin https://github.com/mock-org/mock-repo.git )
cp "$EVAL_TMP/github/sdlc.config.json" "$ov/sdlc.config.json"
out=$(cd "$ov" && SDLC_MOCK_STATE="$EVAL_TMP/override-state" bash "$P/scripts/publish/publish.sh" feature --dry-run 2>/dev/null)
assert_match '^\+ gh issue create' "$(printf '%s\n' "$out" | grep -m1 '^+ gh issue create')" "without --platform the GitHub remote/config decide (gh commands)"
out=$(cd "$ov" && SDLC_MOCK_STATE="$EVAL_TMP/override-state" bash "$P/scripts/publish/publish.sh" feature --platform azure --dry-run 2>"$EVAL_TMP/ov.err"); rc=$?
assert_eq "0" "$rc" "--platform azure on a GitHub remote exits 0 ($(head -c 200 "$EVAL_TMP/ov.err"))"
assert_match '^\+ az boards work-item create' "$(printf '%s\n' "$out" | grep -m1 '^+ az boards work-item create')" "--platform azure overrides the GitHub remote (az commands)"
assert_not_match '^\+ gh ' "$out" "override runs no gh command"
out=$(cd "$ov" && SDLC_PLATFORM=azure SDLC_MOCK_STATE="$EVAL_TMP/override-state" bash "$P/scripts/publish/publish.sh" feature --dry-run 2>/dev/null)
assert_match '^\+ az boards work-item create' "$(printf '%s\n' "$out" | grep -m1 '^+ az boards work-item create')" "SDLC_PLATFORM wins over the git remote when --platform is absent"
out=$(cd "$ov" && bash "$P/scripts/publish/publish.sh" feature --platform gitlab --dry-run 2>&1); rc=$?
assert_eq "2" "$rc" "an unknown --platform is a usage error"
assert_match 'github or azure' "$out" "usage error names the accepted values"

echo "-- a manifest that records another platform stops the run"
gw="$EVAL_TMP/github"
assert_eq "github" "$(jq -r .platform "$gw/feature/publish-manifest.json")" "precondition: github manifest records github"
out=$(cd "$gw" && SDLC_MOCK_STATE="$gw/state" SDLC_PLATFORM_MOCK=1 bash "$P/scripts/publish/publish.sh" feature --platform azure 2>&1); rc=$?
assert_eq "1" "$rc" "manifest mismatch exits 1"
assert_match "records platform 'github'" "$out" "message names the recorded platform"
assert_match "targets 'azure'" "$out" "message names the requested platform"
assert_match -- '--platform github' "$out" "message says how to continue"
assert_eq "github" "$(jq -r .platform "$gw/feature/publish-manifest.json")" "mismatch run did not rewrite the manifest"

echo "-- a manifest with published items but no platform field stops the run"
np="$EVAL_TMP/noplatform"; mkdir -p "$np"; cp -r "$gw/feature" "$np/feature"; cp "$gw/sdlc.config.json" "$np/sdlc.config.json"
jq 'del(.platform)' "$gw/feature/publish-manifest.json" >"$np/feature/publish-manifest.json"
out=$(cd "$np" && SDLC_MOCK_STATE="$EVAL_TMP/np-state" SDLC_PLATFORM_MOCK=1 bash "$P/scripts/publish/publish.sh" feature --platform github 2>&1); rc=$?
assert_eq "1" "$rc" "manifest without platform exits 1"
assert_match 'no "platform" field' "$out" "message asks for the platform field"
assert_eq "null" "$(jq -c '.platform' "$np/feature/publish-manifest.json")" "the field was not guessed and written"

echo "-- a file marker naming another platform stops the run"
mk="$EVAL_TMP/marker"; mkdir -p "$mk"; cp -r "$EVAL_ROOT/fixtures/feature-mock" "$mk/feature"; cp "$EVAL_TMP/azure/sdlc.config.json" "$mk/sdlc.config.json"
{ printf '<!-- sdlc-publish: id=42 url=https://github.com/mock-org/mock-repo/issues/42 platform=github -->\n'; cat "$EVAL_ROOT/fixtures/feature-mock/spec.md"; } >"$mk/feature/spec.md"
out=$(cd "$mk" && SDLC_MOCK_STATE="$EVAL_TMP/mk-state" SDLC_PLATFORM_MOCK=1 bash "$P/scripts/publish/publish.sh" feature --platform azure 2>&1); rc=$?
assert_eq "1" "$rc" "marker for another platform exits 1"
assert_match "marker for platform 'github'" "$out" "message names the marker's platform"
assert_no_file "$mk/feature/publish-manifest.json" "refused run wrote no manifest"
assert_no_file "$EVAL_TMP/mk-state/wi.counter" "refused run created nothing on the tracker"

eval_done
