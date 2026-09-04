#!/usr/bin/env bash
# scripts/ci/azure-review.sh fails closed: exit 0 and status "ok" only when claude exits 0, the
# result JSON says success, and the review file holds exactly one "Blocking: <n>" line; every
# other outcome writes the FAILED diagnostic, status "failed", exit 1. The prompt carries the
# base branch literally (slashes, ampersands, spaces, backslashes, regex metacharacters).
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
S="$P/scripts/ci/azure-review.sh"

# a fake claude first on PATH; behaviour selected by FAKE_CLAUDE, prompt echoed to a file
mkdir -p "$EVAL_TMP/bin"
cat >"$EVAL_TMP/bin/claude" <<'FAKE'
#!/usr/bin/env bash
prompt=""; while [ $# -gt 0 ]; do case "$1" in -p) prompt="${2:-}"; shift 2 ;; *) shift ;; esac; done
[ -n "${FAKE_CLAUDE_PROMPT_FILE:-}" ] && printf '%s' "$prompt" >"$FAKE_CLAUDE_PROMPT_FILE"
ok='{"type":"result","subtype":"success","is_error":false,"num_turns":3,"total_cost_usd":0.12,"result":"done"}'
report() { printf '# Security review: PR against main\n\nBlocking: %s  Important: 0  Nit: 1 (cap 5)\n\n## Blocking\n- none\n\nAdvisory review by ai-sdlc; a human required reviewer approves.\n' "$1"; }
case "${FAKE_CLAUDE:-ok}" in
  fail) echo "fake claude: API error" >&2; exit 1 ;;
  nofile) echo "$ok"; exit 0 ;;
  malformed) printf '# Security review\n\nNo summary line here.\n' >review.md; echo "$ok"; exit 0 ;;
  caps) printf '# partial\n' >review.md; echo '{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":5,"total_cost_usd":0.9}'; exit 0 ;;
  dup) { report 0; printf 'Blocking: 2\n'; } >review.md; echo "$ok"; exit 0 ;;
  ok) report 0 >review.md; echo "$ok"; exit 0 ;;
  *) echo "fake claude: unknown mode" >&2; exit 9 ;;
esac
FAKE
chmod +x "$EVAL_TMP/bin/claude"
export PATH="$EVAL_TMP/bin:$PATH"
assert_eq "$EVAL_TMP/bin/claude" "$(command -v claude)" "fake claude shadows the real one on PATH"

run_mode() {  # run_mode <mode> -> sets RC, DIR
  DIR="$EVAL_TMP/run-$1"; rm -rf "$DIR"; mkdir -p "$DIR"
  ( cd "$DIR" && FAKE_CLAUDE="$1" bash "$S" --base main --max-turns 5 --max-budget-usd 1 \
      --out review.md --result claude-result.json --status review-status.txt ) >"$DIR/stdout" 2>"$DIR/stderr"
  RC=$?
}
for mode in fail nofile malformed caps dup; do
  run_mode "$mode"
  assert_eq "1" "$RC" "[$mode] exits 1"
  assert_eq "failed" "$(cat "$DIR/review-status.txt" 2>/dev/null)" "[$mode] status file says failed"
  assert_eq "# ai-sdlc review FAILED (no review result)" "$(head -n1 "$DIR/review.md" 2>/dev/null)" "[$mode] review.md starts with the FAILED heading"
  assert_not_match '^Blocking:' "$(cat "$DIR/review.md")" "[$mode] diagnostic never looks like a completed review"
  assert_match 'review FAILED' "$(cat "$DIR/stderr")" "[$mode] stderr reports the failure"
done
run_mode fail;      assert_match 'claude exited with status 1' "$(cat "$DIR/review.md")" "[fail] reason names the exit status"
run_mode nofile;    assert_match 'without writing the review file' "$(cat "$DIR/review.md")" "[nofile] reason names the missing report"
run_mode malformed; assert_match 'exactly one .Blocking: <n>. summary line, found 0' "$(cat "$DIR/review.md")" "[malformed] reason names the missing summary line"
run_mode caps;      assert_match 'turn cap was exhausted .*error_max_turns' "$(cat "$DIR/review.md")" "[caps] reason names the exhausted cap"
run_mode dup;       assert_match 'summary line, found 2' "$(cat "$DIR/review.md")" "[dup] reason counts the duplicate lines"

run_mode ok
assert_eq "0" "$RC" "[ok] exits 0 ($(cat "$DIR/stderr"))"
assert_eq "ok" "$(cat "$DIR/review-status.txt")" "[ok] status file says ok"
assert_eq "# Security review: PR against main" "$(head -n1 "$DIR/review.md")" "[ok] review.md is the report claude wrote"
assert_eq "1" "$(grep -cE '^Blocking:[[:space:]]*[0-9]+' "$DIR/review.md")" "[ok] exactly one Blocking line"
assert_eq "success" "$(jq -r .subtype "$DIR/claude-result.json")" "[ok] result JSON kept for the cost step"

echo "-- stale files never pass as this run's result"
DIR="$EVAL_TMP/stale"; mkdir -p "$DIR"; printf 'Blocking: 0\n' >"$DIR/review.md"; printf 'ok\n' >"$DIR/review-status.txt"
( cd "$DIR" && FAKE_CLAUDE=nofile bash "$S" --base main --out review.md --result claude-result.json --status review-status.txt ) >/dev/null 2>&1; rc=$?
assert_eq "1" "$rc" "stale review.md from an earlier step does not count"
assert_eq "failed" "$(cat "$DIR/review-status.txt")" "stale status file overwritten with failed"

echo "-- the prompt carries the base branch literally"
for base in "release/2026.09" "feat/a&b" "release candidate" 'hot\fix.*[v2]' 'a/b/c'; do
  DIR="$EVAL_TMP/prompt"; rm -rf "$DIR"; mkdir -p "$DIR"
  ( cd "$DIR" && FAKE_CLAUDE=ok FAKE_CLAUDE_PROMPT_FILE="$DIR/prompt.txt" bash "$S" --base "$base" --out review.md --result r.json --status s.txt ) >/dev/null 2>&1; rc=$?
  assert_eq "0" "$rc" "[$base] review runs"
  grep -qF "git diff origin/$base...HEAD" "$DIR/prompt.txt" && _ok "[$base] claude received the literal branch name" || _fail "[$base] prompt" "$(head -c 300 "$DIR/prompt.txt")"
  assert_eq "1" "$(grep -cF "$base" "$DIR/prompt.txt")" "[$base] branch appears exactly once in the prompt"
  printed=$(bash "$S" --base "$base" --print-prompt)
  assert_eq "$(cat "$DIR/prompt.txt")" "$printed" "[$base] --print-prompt shows what claude receives"
done
assert_match 'Write\(review\.md\)|review\.md' "$(bash "$S" --base main --out review.md --print-prompt)" "prompt names the report file"

echo "-- usage errors"
assert_exit 2 "missing --base is a usage error" -- bash "$S" --out review.md
assert_exit 2 "non-numeric --max-turns is a usage error" -- bash "$S" --base main --max-turns many
assert_exit 2 "unknown option is a usage error" -- bash "$S" --base main --bogus

eval_done
