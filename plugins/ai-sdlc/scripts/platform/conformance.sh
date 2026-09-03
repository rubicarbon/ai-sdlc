#!/usr/bin/env bash
# conformance.sh — the same assertions against every adapter, under the bundled CLI mocks.
#
#   bash scripts/platform/conformance.sh [--platform github|azure|all] [--keep]
#
# Creates a scratch git repo per platform (remote + sdlc.config.json), runs every
# contract function through bin/sdlc-platform, checks exit codes and stdout shapes,
# then diffs the normalised key sets between platforms. Exit 1 on any divergence.
set -u
here=$(CDPATH= cd -- "${0%/*}" && pwd -P)
. "$here/../_root.sh" || exit 2
BIN="$SDLC_PLUGIN_ROOT/bin/sdlc-platform"
want="all"; keep=0
while [ $# -gt 0 ]; do case "$1" in --platform) want="$2"; shift 2 ;; --keep) keep=1; shift ;; *) shift ;; esac; done
scratch="${EVAL_TMP:-${SDLC_CONFORMANCE_SCRATCH:-$SDLC_PLUGIN_ROOT/../../.dev/scratch/conformance}}"
mkdir -p "$scratch"; scratch=$(CDPATH= cd -- "$scratch" && pwd -P)
fails=0; checks=0
ok()   { checks=$((checks+1)); printf '  ok    [%s] %s\n' "$1" "$2"; }
bad()  { checks=$((checks+1)); fails=$((fails+1)); printf '  FAIL  [%s] %s\n        %s\n' "$1" "$2" "${3:-}"; }

# expect <platform> <want-exit> <label> -- args...   (sets OUT, ERR, RC)
expect() {
  local p="$1" want="$2" label="$3"; shift 3; [ "${1:-}" = "--" ] && shift
  local errf="$scratch/err.$$"
  OUT=$(SDLC_PLATFORM_MOCK=1 SDLC_MOCK_STATE="$scratch/$p/state" timeout 30 "$BIN" --platform "$p" "$@" 2>"$errf" </dev/null); RC=$?; ERR=$(<"$errf"); rm -f "$errf"
  [ "$RC" = 124 ] && ERR="TIMEOUT after 30s (a CLI call waited on stdin?) $ERR"
  if [ "$RC" = "$want" ]; then ok "$p" "$label (exit $RC)"; else bad "$p" "$label" "expected exit $want, got $RC; stderr: ${ERR:0:400}"; fi
}
# shape <platform> <label> <jq-predicate>   on $OUT
shape() {
  local p="$1" label="$2" pred="$3" r
  r=$(printf '%s' "$OUT" | jq -e "$pred" 2>/dev/null >/dev/null; echo $?)
  if [ "$r" = 0 ]; then ok "$p" "$label"; else bad "$p" "$label" "stdout: ${OUT:0:400}"; fi
}
# Key structure only: every object key path (null values included), array indices dropped.
keys_of() { printf '%s' "$1" | jq -c '[paths | map(select(type=="string"))] | unique | map(select(length>0))'; }

setup_repo() {
  local p="$1" d="$scratch/$p"
  rm -rf "$d"; mkdir -p "$d/state" "$d/repo"
  git -C "$d/repo" init -q -b main
  git -C "$d/repo" config user.email conf@example.com; git -C "$d/repo" config user.name conformance; git -C "$d/repo" config core.autocrlf false
  case "$p" in
    github) git -C "$d/repo" remote add origin https://github.com/mock-org/mock-repo.git ;;
    azure)  git -C "$d/repo" remote add origin https://dev.azure.com/mock-org/mock-proj/_git/mock-repo ;;
  esac
  cat >"$d/repo/sdlc.config.json" <<JSON
{
  "version": 1, "platform": "$p", "tier": 3,
  "repo": {"owner": "mock-org", "name": "mock-repo", "defaultBranch": "main"},
  "review": {"requiredApprovals": 1},
  "github": {"requiredChecks": ["ci", "lint"], "deployWorkflow": "sdlc-deploy.yml"},
  "azure": {"organization": "https://dev.azure.com/mock-org", "project": "mock-proj", "repo": "mock-repo", "workItemType": "User Story", "requiredReviewers": ["lead@example.com"], "pipelineName": "sdlc-mock", "deployPipelineName": "sdlc-mock"},
  "metrics": {"incidentLabel": "incident"},
  "artifacts": {"dir": ".sdlc"}
}
JSON
  printf '# Spec\n\nBody with `code` and **bold**.\n\n- [ ] criterion one\n- [ ] criterion two\n' >"$d/body.md"
  printf 'A comment with "quotes" and a\nsecond line.\n' >"$d/comment.md"
  ( cd "$d/repo" && git add . && git commit -q -m "init" && git commit -q --allow-empty -m 'Revert "Add thing"' -m 'This reverts commit aaa111aaa111aaa111aaa111aaa111aaa111aaa1.' )
}

run_platform() {
  local p="$1" d="$scratch/$p"
  setup_repo "$p"
  cd "$d/repo" || exit 1
  export SDLC_CI_TEMPLATES_DIR="$SDLC_PLUGIN_ROOT/scripts/platform/_mocks/templates"

  expect "$p" 0 "platform_detect from remote" -- platform_detect
  [ "$OUT" = "$p" ] && ok "$p" "platform_detect prints '$p'" || bad "$p" "platform_detect output" "$OUT"

  expect "$p" 0 "work_item_create" -- work_item_create "Spec: mock feature" "$d/body.md" --labels spec,ready-for-agent
  shape "$p" "work_item_create shape" '(.id|type)=="string" and (.url|test("^https://")) and .platform=="'"$p"'"'
  SPEC_ID=$(printf '%s' "$OUT" | jq -r .id); SHAPE_CREATE=$(keys_of "$OUT")

  expect "$p" 0 "work_item_create with --parent" -- work_item_create "Ticket 1" "$d/body.md" --labels ready-for-agent --parent "$SPEC_ID"
  T1=$(printf '%s' "$OUT" | jq -r .id)
  expect "$p" 0 "work_item_create second ticket" -- work_item_create "Ticket 2" "$d/body.md" --parent "$SPEC_ID"
  T2=$(printf '%s' "$OUT" | jq -r .id)
  [ "$T1" != "$T2" ] && ok "$p" "ids are distinct" || bad "$p" "ids are distinct" "$T1 vs $T2"

  expect "$p" 0 "work_item_get" -- work_item_get "$SPEC_ID"
  shape "$p" "work_item_get shape" '.id=="'"$SPEC_ID"'" and (.title|type=="string") and (.body|type=="string") and (.state=="open" or .state=="closed") and (.labels|type=="array") and (.url|type=="string") and (.created_at|type=="string") and has("closed_at") and (.assignees|type=="array")'
  SHAPE_GET=$(keys_of "$OUT")

  expect "$p" 0 "work_item_link blocks" -- work_item_link "$T1" "$T2" --type blocks
  shape "$p" "work_item_link shape" '.from=="'"$T1"'" and .to=="'"$T2"'" and .type=="blocks" and (.native|type=="boolean")'
  SHAPE_LINK=$(keys_of "$OUT")
  expect "$p" 0 "work_item_link blocks again (idempotent)" -- work_item_link "$T1" "$T2" --type blocks
  expect "$p" 0 "work_item_link parent" -- work_item_link "$SPEC_ID" "$T1" --type parent
  expect "$p" 0 "work_item_link related" -- work_item_link "$T1" "$T2" --type related
  expect "$p" 2 "work_item_link bad type is a usage error" -- work_item_link "$T1" "$T2" --type sideways

  expect "$p" 0 "work_item_comment" -- work_item_comment "$T1" "$d/comment.md"
  shape "$p" "work_item_comment shape" '.id=="'"$T1"'" and has("comment_id")'
  SHAPE_COMMENT=$(keys_of "$OUT")

  expect "$p" 0 "pr_create" -- pr_create "feat: mock" "$d/body.md" main feature/x
  shape "$p" "pr_create shape" '(.id|type)=="string" and (.url|test("^https://"))'
  PR_ID=$(printf '%s' "$OUT" | jq -r .id); SHAPE_PR_CREATE=$(keys_of "$OUT")

  expect "$p" 0 "pr_get" -- pr_get "$PR_ID"
  shape "$p" "pr_get shape" '.id=="'"$PR_ID"'" and (.state|IN("open","merged","closed")) and (.base|type=="string") and (.head|type=="string") and (.review_decision|IN("approved","changes_requested","pending")) and has("additions") and has("deletions") and has("changed_files") and has("merged_at")'
  SHAPE_PR_GET=$(keys_of "$OUT")

  expect "$p" 0 "pr_comment" -- pr_comment "$PR_ID" "$d/comment.md"
  shape "$p" "pr_comment shape" '.id=="'"$PR_ID"'" and has("comment_id")'
  SHAPE_PR_COMMENT=$(keys_of "$OUT")

  expect "$p" 0 "pr_checks pass" -- pr_checks "$PR_ID"
  shape "$p" "pr_checks pass shape" '.status=="pass" and (.checks|type=="array" and length>0) and (.checks[0]|has("name") and has("status") and has("url"))'
  SHAPE_CHECKS=$(keys_of "$OUT")
  SDLC_MOCK_CHECKS=fail    expect "$p" 1 "pr_checks fail exits 1" -- pr_checks "$PR_ID"
  shape "$p" "pr_checks fail status" '.status=="fail"'
  SDLC_MOCK_CHECKS=pending expect "$p" 8 "pr_checks pending exits 8" -- pr_checks "$PR_ID"
  shape "$p" "pr_checks pending status" '.status=="pending"'

  expect "$p" 0 "branch_protect_apply first run" -- branch_protect_apply main
  shape "$p" "branch_protect_apply shape" '.branch=="main" and (.applied|type=="array") and (.unchanged|type=="array")'
  shape "$p" "branch_protect_apply first run applies something" '(.applied|length)>0'
  SHAPE_PROTECT=$(keys_of "$OUT")
  expect "$p" 0 "branch_protect_apply second run" -- branch_protect_apply main
  shape "$p" "branch_protect_apply second run is a no-op" '(.applied|length)==0 and (.unchanged|length)>0'

  expect "$p" 0 "ci_workflow_install first run" -- ci_workflow_install
  shape "$p" "ci_workflow_install shape" '(.installed|type=="array") and (.unchanged|type=="array") and (.pending|type=="array") and (.registered|type=="array")'
  shape "$p" "ci_workflow_install installs the mock CI file" '(.installed|length)==1'
  SHAPE_CI=$(keys_of "$OUT")
  expect "$p" 0 "ci_workflow_install second run" -- ci_workflow_install
  shape "$p" "ci_workflow_install second run is a no-op" '(.installed|length)==0 and (.unchanged|length)==1 and (.registered|length)==0'
  ci_file=$(find . -path './.git' -prune -o -name 'sdlc-mock.yml' -print | head -n1)
  [ -n "$ci_file" ] && ! grep -q '{{' "$ci_file" && ok "$p" "rendered CI file has no unresolved markers" || bad "$p" "rendered CI file" "${ci_file:-none}"

  expect "$p" 0 "metrics_export" -- metrics_export 2026-08-01 2099-12-31 "$d/metrics.json"
  shape "$p" "metrics_export summary shape" '(.prs|type=="number") and (.deployments|type=="number") and (.incidents|type=="number") and (.reverts|type=="number") and (.out|type=="string")'
  SHAPE_METRICS=$(keys_of "$OUT")
  if jq -e '(.prs|type=="array") and (.deployments|type=="array") and (.incidents|type=="array") and (.reverts|type=="array") and (.deployments|length>=1) and (.prs[0]|has("id") and has("created_at") and has("merged_at") and has("first_review_at") and has("additions") and has("deletions") and has("changed_files") and has("first_commit_at") and has("author") and has("is_revert")) and (.deployments[0]|has("id") and has("environment") and has("started_at") and has("finished_at") and has("status") and has("sha")) and (.incidents[0]|has("id") and has("opened_at") and has("closed_at") and has("labels")) and (.reverts|length>=1)' "$d/metrics.json" >/dev/null 2>&1; then ok "$p" "metrics file schema"; else bad "$p" "metrics file schema" "$(head -c 400 "$d/metrics.json")"; fi
  SHAPE_METRICS_FILE=$(jq -c '[paths | map(select(type=="string"))] | unique | map(select(length>0 and .[0]!="repo" and .[0]!="platform" and .[0]!="exported_at"))' "$d/metrics.json")

  expect "$p" 3 "unsupported function on 'none'" -- --platform none pr_get 1
  # the dispatcher exits 3 before touching the adapter; check the message form
  if [[ "$ERR" =~ ^ai-sdlc:\ not\ supported\ on\ this\ platform: ]]; then ok "$p" "not-supported message form"; else bad "$p" "not-supported message form" "$ERR"; fi

  expect "$p" 0 "dry-run prints commands and no JSON" -- --dry-run work_item_create "Dry" "$d/body.md"
  if [[ "$OUT" =~ ^\+\  ]] && ! [[ "$OUT" =~ \{\"id\" ]]; then ok "$p" "dry-run output form"; else bad "$p" "dry-run output form" "$OUT"; fi

  # static: no cross-platform CLI mentions
  local other; [ "$p" = github ] && other='(^|[^a-z_-])az([^a-z_-]|$)' || other='(^|[^a-z_-])gh([^a-z_-]|$)'
  if grep -Eq "$other" "$SDLC_PLUGIN_ROOT/scripts/platform/$p/"*.sh; then bad "$p" "no foreign CLI mentions in $p adapter" "$(grep -En "$other" "$SDLC_PLUGIN_ROOT/scripts/platform/$p/"*.sh | head -3)"; else ok "$p" "no foreign CLI mentions in $p adapter"; fi

  {
    echo "work_item_create $SHAPE_CREATE"; echo "work_item_get $SHAPE_GET"; echo "work_item_link $SHAPE_LINK"; echo "work_item_comment $SHAPE_COMMENT"
    echo "pr_create $SHAPE_PR_CREATE"; echo "pr_get $SHAPE_PR_GET"; echo "pr_comment $SHAPE_PR_COMMENT"; echo "pr_checks $SHAPE_CHECKS"
    echo "branch_protect_apply $SHAPE_PROTECT"; echo "ci_workflow_install $SHAPE_CI"; echo "metrics_export $SHAPE_METRICS"; echo "metrics_file $SHAPE_METRICS_FILE"
  } >"$scratch/shapes-$p.txt"
  cd "$scratch" || exit 1
}

platforms=()
case "$want" in all) platforms=(github azure) ;; *) platforms=("$want") ;; esac
for p in "${platforms[@]}"; do echo "== $p"; run_platform "$p"; done

if [ "${#platforms[@]}" = 2 ]; then
  echo "== cross-platform"
  if diff -u "$scratch/shapes-github.txt" "$scratch/shapes-azure.txt" >"$scratch/shapes.diff"; then ok "both" "identical stdout key sets for every function"; else bad "both" "stdout key sets differ" "$(cat "$scratch/shapes.diff")"; fi
fi
[ "$keep" = 1 ] || rm -rf "${scratch:?}"/*/state
echo
echo "conformance: $checks check(s), $fails failed"
[ "$fails" -eq 0 ]
