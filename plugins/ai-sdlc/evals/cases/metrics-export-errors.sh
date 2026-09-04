#!/usr/bin/env bash
# metrics_export never converts a CLI failure into empty data, names its sources and
# warns about partial coverage, identically on GitHub and Azure DevOps.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
BIN="$P/bin/sdlc-platform"
export SDLC_PLATFORM_MOCK=1

GH_CFG='{"version":1,"platform":"github","repo":{"owner":"mock-org","name":"mock-repo","defaultBranch":"main"},"github":{"requiredChecks":["ci"]},"metrics":{"incidentLabel":"incident"}}'
GH_CFG_WF='{"version":1,"platform":"github","repo":{"owner":"mock-org","name":"mock-repo","defaultBranch":"main"},"github":{"deployWorkflow":"sdlc-deploy.yml"},"metrics":{"incidentLabel":"incident"}}'
AZ_CFG='{"version":1,"platform":"azure","repo":{"defaultBranch":"main"},"azure":{"organization":"https://dev.azure.com/mock-org","project":"mock-proj","repo":"mock-repo"},"metrics":{"incidentLabel":"incident"}}'
AZ_CFG_DEP='{"version":1,"platform":"azure","repo":{"defaultBranch":"main"},"azure":{"organization":"https://dev.azure.com/mock-org","project":"mock-proj","repo":"mock-repo","deployPipelineId":"42"},"metrics":{"incidentLabel":"incident"}}'

mkrepo() {  # mkrepo <dir> <config-json> [old]   ("old" adds a commit dated before <since>)
  rm -rf "$1"; mkdir -p "$1"; git -C "$1" init -q -b main
  git -C "$1" config user.email e@x; git -C "$1" config user.name e; git -C "$1" config core.autocrlf false
  printf '%s\n' "$2" >"$1/sdlc.config.json"; git -C "$1" add -A >/dev/null
  if [ "${3:-}" = old ]; then
    GIT_AUTHOR_DATE=2020-01-01T00:00:00Z GIT_COMMITTER_DATE=2020-01-01T00:00:00Z git -C "$1" commit -q -m init
  else
    git -C "$1" commit -q -m init
  fi
  git -C "$1" commit -q --allow-empty -m 'Revert "Add thing"' -m 'This reverts commit aaa111aaa111aaa111aaa111aaa111aaa111aaa1.'
}
# export <platform> <repo> <out> [env...] -> OUT RC ERR
export_() {
  local p="$1" d="$2" out="$3"; shift 3
  OUT=$(cd "$d" && env SDLC_MOCK_STATE="$EVAL_TMP/state-$p" "$@" "$BIN" --platform "$p" metrics_export 2026-08-01 2099-12-31 "$out" 2>"$EVAL_TMP/err" </dev/null); RC=$?
  ERR=$(<"$EVAL_TMP/err")
}
mkdir -p "$EVAL_TMP/state-github" "$EVAL_TMP/state-azure"

for p in github azure; do
  case "$p" in
    github) cfg="$GH_CFG"; failcmd="pr list"; label='gh pr list --repo mock-org/mock-repo --state merged'; ci="gh" ;;
    azure)  cfg="$AZ_CFG"; failcmd="repos pr list"; label='az repos pr list --repository mock-repo --status completed'; ci="az" ;;
  esac
  r="$EVAL_TMP/$p"; mkrepo "$r" "$cfg" old

  echo "-- $p: API failure"
  export_ "$p" "$r" "$r/out/fail.json" SDLC_MOCK_FAIL="$failcmd"
  assert_eq "1" "$RC" "$p: failed PR query exits 1"
  assert_match "ai-sdlc: $label failed \(exit 1\): " "$ERR" "$p: stderr names the command and exit code"
  assert_no_file "$r/out/fail.json" "$p: no output file after a failure"
  assert_eq "" "$OUT" "$p: no summary JSON after a failure"

  echo "-- $p: malformed JSON"
  export_ "$p" "$r" "$r/out/bad.json" SDLC_MOCK_MALFORMED="$failcmd"
  assert_eq "1" "$RC" "$p: malformed JSON exits 1"
  assert_match "ai-sdlc: $label returned invalid JSON" "$ERR" "$p: stderr says invalid JSON"
  assert_no_file "$r/out/bad.json" "$p: no output file after malformed JSON"

  echo "-- $p: a later call failing also leaves no file"
  case "$p" in github) later="issue list" ;; azure) later="boards query" ;; esac
  export_ "$p" "$r" "$r/out/later.json" SDLC_MOCK_FAIL="$later"
  assert_eq "1" "$RC" "$p: failed incident query exits 1"
  assert_match "ai-sdlc: $ci $later" "$ERR" "$p: stderr names the incident command"
  assert_no_file "$r/out/later.json" "$p: no output file when the incident query fails"

  echo "-- $p: empty valid result"
  export_ "$p" "$r" "$r/out/empty.json" SDLC_MOCK_EMPTY="$failcmd"
  assert_eq "0" "$RC" "$p: empty PR list exits 0 ($ERR)"
  assert_eq "0" "$(printf '%s' "$OUT" | jq -r .prs)" "$p: prs count 0"
  assert_file "$r/out/empty.json" "$p: output file written"
  assert_eq "configured" "$(jq -r .sources.prs "$r/out/empty.json")" "$p: prs source is configured"
  assert_not_match 'pull request' "$(jq -c .warnings "$r/out/empty.json")" "$p: no warning about pull requests for an empty period"
  assert_eq "configured" "$(jq -r .sources.reverts "$r/out/empty.json")" "$p: reverts source configured (history older than since)"
  assert_not_match 'git history' "$(jq -c .warnings "$r/out/empty.json")" "$p: no history warning"
  assert_eq "$(jq -c .warnings "$r/out/empty.json")" "$(printf '%s' "$OUT" | jq -c .warnings)" "$p: summary warnings equal the file's"

  echo "-- $p: partial local history (first commit newer than since)"
  rn="$EVAL_TMP/$p-new"; mkrepo "$rn" "$cfg"
  export_ "$p" "$rn" "$rn/out/new.json"
  assert_eq "0" "$RC" "$p: export with young history exits 0 ($ERR)"
  assert_eq "partial" "$(jq -r .sources.reverts "$rn/out/new.json")" "$p: reverts source is partial"
  assert_match 'no commit older than 2026-08-01' "$(jq -c .warnings "$rn/out/new.json")" "$p: warning explains the missing history"
  assert_eq "1" "$(jq -r '.reverts|length' "$rn/out/new.json")" "$p: the local revert is still exported"

  echo "-- $p: shallow clone"
  rs="$EVAL_TMP/$p-shallow"; rm -rf "$rs"
  if git clone -q --depth 1 "file://$r" "$rs" 2>/dev/null && [ "$(git -C "$rs" rev-parse --is-shallow-repository)" = true ]; then
    export_ "$p" "$rs" "$rs/out/shallow.json"
    assert_eq "0" "$RC" "$p: export from a shallow clone exits 0 ($ERR)"
    assert_eq "partial" "$(jq -r .sources.reverts "$rs/out/shallow.json")" "$p: shallow clone -> reverts partial"
    assert_match 'shallow' "$(jq -c .warnings "$rs/out/shallow.json")" "$p: shallow warning"
  else
    _ok "$p: shallow file:// clone unavailable here, covered by the young-history case"
  fi
done

echo "-- summary key sets are identical"
export_ github "$EVAL_TMP/github" "$EVAL_TMP/github/out/k.json"; kg=$(printf '%s' "$OUT" | jq -c 'keys')
export_ azure "$EVAL_TMP/azure" "$EVAL_TMP/azure/out/k.json"; ka=$(printf '%s' "$OUT" | jq -c 'keys')
assert_eq "$kg" "$ka" "summary keys match ($kg)"
assert_eq "$(jq -c '.sources|keys' "$EVAL_TMP/github/out/k.json")" "$(jq -c '.sources|keys' "$EVAL_TMP/azure/out/k.json")" "sources keys match"

echo "-- deployments configuration"
assert_eq "not-configured" "$(jq -r .sources.deployments "$EVAL_TMP/azure/out/k.json")" "azure without deployPipelineName/Id and no registered pipeline -> not-configured"
assert_match 'no deploy pipeline configured' "$(jq -c .warnings "$EVAL_TMP/azure/out/k.json")" "azure: warning about the deploy pipeline"
assert_eq "0" "$(jq -r '.deployments|length' "$EVAL_TMP/azure/out/k.json")" "azure: deployments empty"
assert_eq "configured" "$(jq -r .sources.deployments "$EVAL_TMP/github/out/k.json")" "github without deployWorkflow uses the Deployments API -> configured"
assert_eq "2" "$(jq -r '.deployments|length' "$EVAL_TMP/github/out/k.json")" "github: deployments from the API"
azd="$EVAL_TMP/azure-dep"; mkrepo "$azd" "$AZ_CFG_DEP" old
export_ azure "$azd" "$azd/out/dep.json"
assert_eq "0" "$RC" "azure with deployPipelineId exits 0 ($ERR)"
assert_eq "configured" "$(jq -r .sources.deployments "$azd/out/dep.json")" "azure with deployPipelineId -> configured"
assert_eq "2" "$(jq -r '.deployments|length' "$azd/out/dep.json")" "azure: deployments from the pipeline runs"
ghw="$EVAL_TMP/github-wf"; mkrepo "$ghw" "$GH_CFG_WF" old
export_ github "$ghw" "$ghw/out/wf.json"
assert_eq "configured" "$(jq -r .sources.deployments "$ghw/out/wf.json")" "github with deployWorkflow -> configured"
export_ github "$ghw" "$ghw/out/wf-fail.json" SDLC_MOCK_FAIL="run list"
assert_eq "1" "$RC" "github: a failing workflow run query exits 1"
assert_no_file "$ghw/out/wf-fail.json" "github: no file when the run query fails"

echo "-- azure PR size warning"
assert_match '2 of 2 pull requests have no local merge commits; size and first_commit_at are null for them' "$(jq -c .warnings "$EVAL_TMP/azure/out/k.json")" "azure: warns how many PRs lack local commits"
assert_eq "null" "$(jq -c '.prs[0].additions' "$EVAL_TMP/azure/out/k.json")" "azure: size is null for those PRs"

echo "-- dry-run writes no file"
export_ github "$EVAL_TMP/github" "$EVAL_TMP/github/out/dry.json" SDLC_DRY_RUN=1
assert_eq "0" "$RC" "github dry-run exits 0"
assert_no_file "$EVAL_TMP/github/out/dry.json" "github dry-run wrote no file"
export_ azure "$EVAL_TMP/azure" "$EVAL_TMP/azure/out/dry.json" SDLC_DRY_RUN=1
assert_eq "0" "$RC" "azure dry-run exits 0"
assert_no_file "$EVAL_TMP/azure/out/dry.json" "azure dry-run wrote no file"
assert_not_match 'Authorization' "$OUT" "azure dry-run never prints an Authorization header"
eval_done
