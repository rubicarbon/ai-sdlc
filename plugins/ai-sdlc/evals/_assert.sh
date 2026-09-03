#!/usr/bin/env bash
# _assert.sh — helpers for eval cases. Source from evals/cases/*.sh.
# Every case script exits non-zero on the first failed assertion; run.sh aggregates.

: "${EVAL_NAME:=${0##*/}}"
EVAL_FAILS=0
case "${OSTYPE:-}" in msys*|cygwin*|win32*) jq() { command jq -b "$@"; } ;; esac   # Windows jq writes CRLF

_ok()   { printf '  ok    %s\n' "$1"; }
_fail() { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; EVAL_FAILS=$((EVAL_FAILS+1)); }

assert_eq() {      # assert_eq <expected> <actual> <label>
  if [ "$1" = "$2" ]; then _ok "$3"; else _fail "$3" "expected '$1', got '$2'"; fi
}
assert_exit() {    # assert_exit <expected-code> <label> -- command...
  local want="$1" label="$2"; shift 2; [ "${1:-}" = "--" ] && shift
  local out; out=$("$@" 2>&1); local got=$?
  if [ "$got" = "$want" ]; then _ok "$label (exit $got)"; else _fail "$label" "expected exit $want, got $got; output: ${out:0:300}"; fi
}
assert_match() {   # assert_match <regex> <text> <label>
  if [[ "$2" =~ $1 ]]; then _ok "$3"; else _fail "$3" "'${2:0:300}' does not match /$1/"; fi
}
assert_not_match() {
  if [[ "$2" =~ $1 ]]; then _fail "$3" "'${2:0:300}' matches /$1/ but must not"; else _ok "$3"; fi
}
assert_file() { if [ -f "$1" ]; then _ok "$2"; else _fail "$2" "missing file $1"; fi; }
assert_no_file() { if [ ! -e "$1" ]; then _ok "$2"; else _fail "$2" "unexpected file $1"; fi; }

# run_hook <hook-script> <json-stdin> [env assignments...] -> sets HOOK_EXIT, HOOK_ERR, HOOK_OUT
run_hook() {
  local hook="$1" json="$2"; shift 2
  local errf; errf=$(mktemp "${EVAL_TMP:-/tmp}/hookerr.XXXXXX")
  HOOK_OUT=$(env "$@" bash "$hook" <<<"$json" 2>"$errf"); HOOK_EXIT=$?
  HOOK_ERR=$(<"$errf"); rm -f "$errf"
}

# hook_json <tool> <tool_input-json> [cwd] -> PreToolUse input JSON
hook_json() {
  printf '{"session_id":"eval","cwd":"%s","hook_event_name":"PreToolUse","permission_mode":"default","tool_name":"%s","tool_input":%s}' "${3:-$PWD}" "$1" "$2"
}

eval_done() {
  if [ "$EVAL_FAILS" -eq 0 ]; then echo "PASS $EVAL_NAME"; exit 0; else echo "FAIL $EVAL_NAME ($EVAL_FAILS assertion(s))"; exit 1; fi
}
