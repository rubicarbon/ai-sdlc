#!/usr/bin/env bash
# Release authorisation markers: gate-production.sh and preflight.sh accept only a complete,
# unexpired marker whose commit is HEAD and matches the file name; authorize.sh writes such a
# marker and refuses to run inside a Claude Code session.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
H="$P/hooks"

proj="$EVAL_TMP/proj"; mkdir -p "$proj"
cp "$EVAL_ROOT/fixtures/sdlc-project/sdlc.config.json" "$proj/"
git -C "$proj" init -q -b main; git -C "$proj" config user.email e@x; git -C "$proj" config user.name e
printf 'x\n' >"$proj/README.md"; ( cd "$proj" && git add -A >/dev/null && git commit -q -m init )
head=$(git -C "$proj" rev-parse HEAD)
other=0123456789abcdef0123456789abcdef01234567
R="$proj/.sdlc/release"; mkdir -p "$R"
future=$(( $(date +%s) + 7200 )); past=$(( $(date +%s) - 60 ))

push_json=$(hook_json Bash "$(jq -cn '{command:"git push origin main"}')" "$proj")
write_marker() {  # write_marker <file-name> <lines...>
  local n="$1"; shift
  rm -f "$R"/AUTHORIZED-*
  : >"$R/$n"; for l in "$@"; do printf '%s\n' "$l" >>"$R/$n"; done
}
gate() {  # gate <want-exit> <label> [reason-regex]
  run_hook "$H/gate-production.sh" "$push_json" SDLC_CWD="$proj"
  if [ "$HOOK_EXIT" = "$1" ]; then _ok "$2 (exit $HOOK_EXIT)"; else _fail "$2" "expected $1 got $HOOK_EXIT; stderr: ${HOOK_ERR:0:300}"; fi
  [ -n "${3:-}" ] && assert_match "$3" "$HOOK_ERR" "$2: reason"
  return 0
}
authz_gate() {  # authz_gate <want-ok> <label>
  local out; out=$(cd "$proj" && bash "$P/scripts/ship/preflight.sh" 2>/dev/null)
  assert_eq "$1" "$(jq -r '.gates[] | select(.gate=="release authorised for HEAD") | .ok' <<<"$out")" "$2"
}
ok_by="authorised_by=human"; ok_at="authorised_at=2026-09-04T10:00:00Z"
ok_exp="expires=$future"; ok_exp_at="expires_at=2026-09-04T12:00:00Z"; ok_commit="commit=$head"

echo "-- pattern matching is unchanged"
run_hook "$H/gate-production.sh" "$(hook_json Bash "$(jq -cn '{command:"git status"}')" "$proj")" SDLC_CWD="$proj"
assert_eq "0" "$HOOK_EXIT" "git status is not a production command"

echo "-- missing and empty markers"
rm -f "$R"/AUTHORIZED-*
gate 2 "no marker denies" 'no release authorisation.*sdlc-ship'
authz_gate false "preflight: no marker"
write_marker "AUTHORIZED-$head"
gate 2 "empty marker denies" 'empty'
authz_gate false "preflight: empty marker"

echo "-- missing fields"
write_marker "AUTHORIZED-$head" "$ok_by" "$ok_at" "$ok_exp_at" "$ok_commit"
gate 2 "missing expires= denies" 'no expires= line'
write_marker "AUTHORIZED-$head" "$ok_by" "$ok_at" "$ok_exp" "$ok_exp_at"
gate 2 "missing commit= denies" 'no commit= line'
write_marker "AUTHORIZED-$head" "$ok_at" "$ok_exp" "$ok_exp_at" "$ok_commit"
gate 2 "missing authorised_by= denies" 'no authorised_by= line'
write_marker "AUTHORIZED-$head" "$ok_by" "$ok_exp" "$ok_exp_at" "$ok_commit"
gate 2 "missing authorised_at= denies" 'no authorised_at= line'

echo "-- duplicated fields"
write_marker "AUTHORIZED-$head" "$ok_by" "$ok_at" "$ok_exp" "expires=$past" "$ok_exp_at" "$ok_commit"
gate 2 "two expires= lines deny" '2 expires= lines'
write_marker "AUTHORIZED-$head" "$ok_by" "$ok_at" "$ok_exp" "$ok_exp_at" "$ok_commit" "$ok_commit"
gate 2 "two commit= lines deny" '2 commit= lines'
write_marker "AUTHORIZED-$head" "$ok_by" "authorised_by=other" "$ok_at" "$ok_exp" "$ok_exp_at" "$ok_commit"
gate 2 "two authorised_by= lines deny" '2 authorised_by= lines'
write_marker "AUTHORIZED-$head" "$ok_by" "$ok_at" "$ok_at" "$ok_exp" "$ok_exp_at" "$ok_commit"
gate 2 "two authorised_at= lines deny" '2 authorised_at= lines'

echo "-- malformed values"
write_marker "AUTHORIZED-$head" "$ok_by" "$ok_at" "expires=tomorrow" "$ok_exp_at" "$ok_commit"
gate 2 "non-numeric expires= denies" 'non-numeric expires'
write_marker "AUTHORIZED-$head" "$ok_by" "$ok_at" "expires=$past" "$ok_exp_at" "$ok_commit"
gate 2 "expired marker denies" 'expired'
authz_gate false "preflight: expired marker"
write_marker "AUTHORIZED-$head" "$ok_by" "$ok_at" "expires=$(date +%s)" "$ok_exp_at" "$ok_commit"
gate 2 "expiry equal to now denies" 'expired'
write_marker "AUTHORIZED-$head" "$ok_by" "$ok_at" "$ok_exp" "$ok_exp_at" "commit=${head:0:12}"
gate 2 "short commit= denies" 'malformed commit'
write_marker "AUTHORIZED-$head" "$ok_by" "$ok_at" "$ok_exp" "$ok_exp_at" "commit=$other"
gate 2 "commit= for another sha denies" 'names commit'
write_marker "AUTHORIZED-$other" "$ok_by" "$ok_at" "$ok_exp" "$ok_exp_at" "commit=$other"
gate 2 "marker named for another commit denies" 'no release authorisation'
authz_gate false "preflight: marker for another commit"
write_marker "AUTHORIZED-$head" "authorised_by=" "$ok_at" "$ok_exp" "$ok_exp_at" "$ok_commit"
gate 2 "empty authorised_by= denies" 'empty authorised_by'
write_marker "AUTHORIZED-$head" "$ok_by" "authorised_at=   " "$ok_exp" "$ok_exp_at" "$ok_commit"
gate 2 "blank authorised_at= denies" 'empty authorised_at'

echo "-- valid marker"
write_marker "AUTHORIZED-$head" "$ok_by" "$ok_at" "$ok_exp" "$ok_exp_at" "$ok_commit"
gate 0 "complete fresh marker for HEAD allows"
authz_gate true "preflight: valid marker"
printf 'authorised_by=human\r\nauthorised_at=t\r\nexpires=%s\r\nexpires_at=x\r\ncommit=%s\r\n' "$future" "$head" >"$R/AUTHORIZED-$head"
gate 0 "CRLF marker is read"

echo "-- library: file name and content must agree"
authz="$P/scripts/ship/_authz.sh"
lib() { bash -c '. "$1"; . "$2"; sdlc_check_authorization "$3" "$4"' _ "$P/scripts/_lib.sh" "$authz" "$@"; }
write_marker "AUTHORIZED-$head" "$ok_by" "$ok_at" "$ok_exp" "$ok_exp_at" "$ok_commit"
assert_exit 0 "library accepts the valid marker" -- lib "$R/AUTHORIZED-$head" "$head"
assert_exit 1 "library rejects the valid marker against another HEAD" -- lib "$R/AUTHORIZED-$head" "$other"
cp "$R/AUTHORIZED-$head" "$R/AUTHORIZED-$other"
out=$(lib "$R/AUTHORIZED-$other" "$other"); rc=$?
assert_eq "1" "$rc" "file name and commit= disagreement is invalid"
assert_match 'names commit' "$out" "reason names the disagreement"
cp "$R/AUTHORIZED-$head" "$R/ALLOWED-$head"
out=$(lib "$R/ALLOWED-$head" "$head"); rc=$?
assert_eq "1" "$rc" "a marker not named AUTHORIZED-<sha> is invalid"
rm -f "$R"/AUTHORIZED-* "$R"/ALLOWED-*

echo "-- authorize.sh"
auth="$P/scripts/ship/authorize.sh"
out=$(cd "$proj" && CLAUDECODE=1 bash "$auth" --by tester 2>&1); rc=$?
assert_eq "2" "$rc" "authorize.sh refuses inside a Claude Code session"
assert_match 'human' "$out" "refusal explains a human must run it"
assert_no_file "$R/AUTHORIZED-$head" "refusal writes nothing"
out=$(cd "$proj" && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_PROJECT_DIR bash "$auth" --by tester --ttl-minutes 30 2>&1); rc=$?
assert_eq "0" "$rc" "authorize.sh runs from a plain terminal"
assert_file "$R/AUTHORIZED-$head" "marker written for HEAD"
content=$(<"$R/AUTHORIZED-$head")
assert_match 'authorised_by=tester' "$content" "marker records the identity"
assert_match 'authorised_at=[0-9]{4}-' "$content" "marker records the time"
assert_match 'expires=[0-9]+' "$content" "marker records a numeric expiry"
assert_match "commit=$head" "$content" "marker records the full sha"
assert_exit 0 "written marker passes the validator" -- lib "$R/AUTHORIZED-$head" "$head"
gate 0 "written marker opens the production gate"
authz_gate true "preflight: written marker"
out=$(cd "$proj" && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_PROJECT_DIR bash "$auth" --sha deadbeef 2>&1); rc=$?
assert_eq "1" "$rc" "unknown commit is refused"

eval_done
