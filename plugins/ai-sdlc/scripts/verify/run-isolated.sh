#!/usr/bin/env bash
# run-isolated.sh — run the configured verification command in a disposable git worktree.
#
#   run-isolated.sh [--ref <rev>] [--tail N]
#
# The sdlc-verifier and sdlc-security-auditor subagents may not run test runners, build tools
# or scripts in the main checkout (hooks/guard-verifier-readonly.sh denies them). This helper
# is the one sanctioned way to execute the project's commands.verify: it checks out <rev>
# (default HEAD) into a fresh worktree under <artifacts>/tmp/ (or $SDLC_TMPDIR), runs the
# optional commands.verifySetup and then commands.verify there, removes the worktree, and
# proves that the main checkout is unchanged by comparing a fingerprint of HEAD, the index,
# every tracked modification and every untracked, non-ignored file taken before and after.
#
# Output: one JSON line on stdout
#   {"command","setup","ref","verified_sha","head","exit","log","tail":[...],
#    "dirty_main_checkout":bool,"main_checkout_unchanged":bool}
# Exit codes: 0 verify passed; 1 verify (or setup) failed; 2 usage or environment error;
# 4 the main checkout changed during the run (report this: something escaped the worktree).
#
# Only committed content reaches the worktree. Uncommitted changes in the main checkout are
# reported as dirty_main_checkout=true and are NOT verified; commit first.
set -u
. "${0%/*}/../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"
SDLC_PROJECT_OPTIONAL=1 . "$SDLC_PLUGIN_ROOT/scripts/_project.sh"
[ -n "${SDLC_PROJECT_DIR:-}" ] || sdlc_die 2 "run-isolated.sh: no sdlc.config.json found (not an sdlc project)"

ref=HEAD; tail_n=40
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) ref="${2:-}"; shift 2 ;;
    --tail) tail_n="${2:-}"; shift 2 ;;
    *) sdlc_die 2 "run-isolated.sh [--ref <rev>] [--tail N]" ;;
  esac
done
[[ "$tail_n" =~ ^[0-9]+$ ]] || sdlc_die 2 "run-isolated.sh: --tail needs a number"
verify=$(sdlc_config '.commands.verify' '')
setup=$(sdlc_config '.commands.verifySetup' '')
[ -n "$verify" ] || sdlc_die 2 "run-isolated.sh: commands.verify is not set in sdlc.config.json"

main="$SDLC_PROJECT_DIR"
git -C "$main" rev-parse --verify "$ref^{commit}" >/dev/null 2>&1 \
  || sdlc_die 2 "run-isolated.sh: unknown revision '$ref' (nothing committed yet?)"
sha=$(git -C "$main" rev-parse "$ref^{commit}")
head_sha=$(git -C "$main" rev-parse HEAD)

# fingerprint of the main checkout: HEAD, index, tracked changes, untracked non-ignored files
fingerprint() {
  local tmp; tmp=$(sdlc_tmpfile)
  {
    git -C "$main" rev-parse HEAD
    git -C "$main" ls-files -s
    git -C "$main" diff HEAD --no-color --no-ext-diff
    git -C "$main" ls-files --others --exclude-standard | LC_ALL=C sort | while IFS= read -r f; do
      [ -n "$f" ] || continue
      printf '%s ' "$f"; sdlc_sha256 "$main/$f"
    done
  } >"$tmp"
  sdlc_sha256 "$tmp"; rm -f "$tmp"
}
dirty=false; [ -n "$(git -C "$main" status --porcelain 2>/dev/null)" ] && dirty=true
before=$(fingerprint)

# disposable worktree: under <artifacts>/tmp when that path is ignored, else $SDLC_TMPDIR/TMPDIR
art=$(sdlc_artifacts_dir)
base="${SDLC_TMPDIR:-}"
if [ -z "$base" ]; then
  if git -C "$main" check-ignore -q "$art/tmp/probe" 2>/dev/null; then base="$art/tmp"
  else base="${TMPDIR:-/tmp}"; fi
fi
mkdir -p "$base" || sdlc_die 2 "run-isolated.sh: cannot create $base"
wt=$(mktemp -d "$base/sdlc-verify.XXXXXX") || sdlc_die 2 "run-isolated.sh: cannot create a worktree dir"
log="$base/sdlc-verify-$(date -u +%Y%m%dT%H%M%SZ)-${sha:0:12}.log"

cleanup() {
  git -C "$main" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
  git -C "$main" worktree prune >/dev/null 2>&1 || true
}
trap cleanup EXIT

rmdir "$wt" 2>/dev/null || true
git -C "$main" worktree add --detach "$wt" "$sha" >/dev/null 2>"$log" \
  || sdlc_die 2 "run-isolated.sh: git worktree add failed: $(head -n1 "$log")"

rc=0
{
  echo "== ai-sdlc run-isolated: ref $sha in $wt"
  if [ -n "$setup" ]; then
    echo "== setup: $setup"
    ( cd "$wt" && SDLC_VERIFY_ISOLATED=1 bash -c "$setup" ) 2>&1 || { rc=$?; echo "== setup exit $rc"; }
  fi
  if [ $rc -eq 0 ]; then
    echo "== verify: $verify"
    ( cd "$wt" && SDLC_VERIFY_ISOLATED=1 bash -c "$verify" ) 2>&1 || rc=$?
    echo "== verify exit $rc"
  fi
} >"$log" 2>&1

cleanup; trap - EXIT
after=$(fingerprint)
unchanged=true; [ "$before" = "$after" ] || unchanged=false

tail_json=$(tail -n "$tail_n" "$log" | jq -R . | jq -cs .)
jq -cn --arg cmd "$verify" --arg setup "$setup" --arg ref "$ref" --arg sha "$sha" --arg head "$head_sha" \
  --argjson rc "$rc" --arg log "$log" --argjson tail "$tail_json" --argjson dirty "$dirty" --argjson un "$unchanged" \
  '{command:$cmd, setup:(if $setup=="" then null else $setup end), ref:$ref, verified_sha:$sha, head:$head,
    exit:$rc, log:$log, tail:$tail, dirty_main_checkout:$dirty, main_checkout_unchanged:$un}'
if [ "$unchanged" = false ]; then
  echo "ai-sdlc: the main checkout changed while the verification command ran in the worktree; treat the run as untrusted and report it" >&2
  exit 4
fi
[ $rc -eq 0 ] && exit 0
exit 1
