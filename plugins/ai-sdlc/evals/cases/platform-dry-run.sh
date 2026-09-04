#!/usr/bin/env bash
# --dry-run never mutates the target repository: the tree hash of a scratch repo is the
# same before and after every dry-run call on both platforms (mock state lives outside).
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
BIN="$P/bin/sdlc-platform"
export SDLC_PLATFORM_MOCK=1 SDLC_CI_TEMPLATES_DIR="$P/scripts/platform/_mocks/templates"

tree_hash() {  # sha256 over the sorted file list and contents, .git excluded
  ( cd "$1" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while read -r f; do
      printf '%s ' "$f"; sha256sum "$f" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$f" | cut -d' ' -f1; done ) | sha256sum | cut -d' ' -f1
}
mkrepo() {  # mkrepo <dir> <platform>
  rm -rf "$1"; mkdir -p "$1"; git -C "$1" init -q -b main
  git -C "$1" config user.email e@x; git -C "$1" config user.name e; git -C "$1" config core.autocrlf false
  case "$2" in
    github) printf '%s\n' '{"version":1,"platform":"github","repo":{"owner":"mock-org","name":"mock-repo","defaultBranch":"main"},"github":{"requiredChecks":["ci"],"deployWorkflow":"sdlc-deploy.yml"}}' ;;
    azure)  printf '%s\n' '{"version":1,"platform":"azure","repo":{"defaultBranch":"main"},"azure":{"organization":"https://dev.azure.com/mock-org","project":"mock-proj","repo":"mock-repo","requiredReviewers":["lead@example.com"],"pipelineName":"sdlc-mock","deployPipelineName":"sdlc-mock"}}' ;;
  esac >"$1/sdlc.config.json"
  printf '# body\n' >"$1/body.md"
  git -C "$1" add -A >/dev/null; git -C "$1" commit -q -m init
}
# dry <platform> <repo> <label> <function args...>: the tree hash must not change
dry() {
  local p="$1" d="$2" label="$3"; shift 3
  local before after out rc
  before=$(tree_hash "$d")
  out=$(cd "$d" && SDLC_MOCK_STATE="$EVAL_TMP/state-$p" "$BIN" --platform "$p" --dry-run "$@" 2>"$EVAL_TMP/err" </dev/null); rc=$?
  after=$(tree_hash "$d")
  assert_eq "0" "$rc" "$p: --dry-run $label exits 0 ($(head -c 200 "$EVAL_TMP/err"))"
  assert_eq "$before" "$after" "$p: --dry-run $label leaves the repository tree unchanged"
  assert_not_match '^\{' "$out" "$p: --dry-run $label prints no JSON result"
  DRY_OUT="$out"; DRY_ERR=$(<"$EVAL_TMP/err")
}

for p in github azure; do
  r="$EVAL_TMP/$p"; mkrepo "$r" "$p"; mkdir -p "$EVAL_TMP/state-$p"
  echo "-- $p"
  dry "$p" "$r" "ci_workflow_install" ci_workflow_install
  assert_match 'dry-run: would install' "$DRY_ERR" "$p: ci_workflow_install dry-run reports what it would install"
  assert_no_file "$r/.github" "$p: no .github directory created"
  assert_no_file "$r/.azuredevops" "$p: no .azuredevops directory created"
  [ -z "$(cd "$r" && git status --porcelain)" ] && _ok "$p: working tree clean after ci_workflow_install dry-run" || _fail "$p: ci_workflow_install dry-run dirtied the tree" "$(cd "$r" && git status --porcelain)"
  dry "$p" "$r" "metrics_export" metrics_export 2026-08-01 2099-12-31 "$r/.sdlc/metrics/raw.json"
  assert_no_file "$r/.sdlc/metrics/raw.json" "$p: metrics_export dry-run wrote no output file"
  assert_no_file "$r/.sdlc" "$p: metrics_export dry-run created no .sdlc directory"
  dry "$p" "$r" "branch_protect_apply" branch_protect_apply main
  assert_match '^\+ (gh|az) ' "$DRY_OUT" "$p: branch_protect_apply dry-run prints the CLI commands"
  dry "$p" "$r" "work_item_create" work_item_create "Dry" "$r/body.md" --labels spec
  assert_match '^\+ (gh|az) ' "$DRY_OUT" "$p: work_item_create dry-run prints the CLI commands"
  # a real (mock) install afterwards proves the dry-run had not silently done the work
  out=$(cd "$r" && SDLC_MOCK_STATE="$EVAL_TMP/state-$p" "$BIN" --platform "$p" ci_workflow_install 2>/dev/null </dev/null)
  assert_eq "1" "$(printf '%s' "$out" | jq -r '.installed|length')" "$p: the real run still installs the file"
done
eval_done
