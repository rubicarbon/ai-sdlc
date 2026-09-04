#!/usr/bin/env bash
# preflight.sh end to end (no --pr): the verification, security and authorisation gates read
# the saved reports and the release marker through the shared validators and fail closed on
# anything malformed.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
pre="$P/scripts/ship/preflight.sh"

proj="$EVAL_TMP/proj"; mkdir -p "$proj"
git -C "$proj" init -q -b main; git -C "$proj" config user.email e@x; git -C "$proj" config user.name e
printf '{"version":1,"platform":"none","tier":1,"artifacts":{"dir":".sdlc"}}\n' >"$proj/sdlc.config.json"
printf 'x\n' >"$proj/README.md"; ( cd "$proj" && git add -A >/dev/null && git commit -q -m init )
head=$(git -C "$proj" rev-parse HEAD); short="${head:0:7}"
V="$proj/.sdlc/verify"; R="$proj/.sdlc/release"; mkdir -p "$V" "$R"

report() {  # report <name> <verdict> <commit>
  printf '# Verification: x\n\n**Verdict:** %s\n**Commit:** %s  **Base:** main  **Command:** `npm test` exit 0\n' "$2" "$3" >"$V/$1"
}
security() {  # security <blocking> <name> : report with a Commit line for HEAD
  printf '# Security review: x against main\n**Commit:** %s  **Base:** main\n\nBlocking: %s  Important: 0  Nit: 0 (cap 5)\n' "$head" "$1" >"$V/$2"
}
marker() {  # marker <expires-epoch>
  printf 'authorised_by=human\nauthorised_at=2026-09-04T10:00:00Z\nexpires=%s\nexpires_at=later\ncommit=%s\n' "$1" "$head" >"$R/AUTHORIZED-$head"
}
run() { OUT=$(cd "$proj" && bash "$pre" 2>/dev/null); RC=$?; }
gate_ok() { jq -r --arg g "$1" '.gates[] | select(.gate==$g) | .ok' <<<"$OUT"; }
gate_ev() { jq -r --arg g "$1" '.gates[] | select(.gate==$g) | .evidence' <<<"$OUT"; }
gate_names() { jq -r '[.gates[].gate] | join("|")' <<<"$OUT"; }

echo "-- (a) no reports, no marker"
run
assert_eq "1" "$RC" "preflight exits 1 when a gate is red"
assert_eq "$head" "$(jq -r .head <<<"$OUT")" "head is HEAD"
assert_eq "false" "$(jq -r .ready <<<"$OUT")" "ready is false"
assert_eq "verification report PASS|security review present|working tree clean|pull request named|release authorised for HEAD" "$(gate_names)" "gate names without --pr"
assert_eq "false" "$(gate_ok 'verification report PASS')" "verification gate red"
assert_match 'no verification report' "$(gate_ev 'verification report PASS')" "verification evidence names the missing report"
assert_eq "false" "$(gate_ok 'security review present')" "security gate red"
assert_eq "true" "$(gate_ok 'working tree clean')" "working tree gate green"
assert_eq "false" "$(gate_ok 'pull request named')" "pull request gate red without --pr"
assert_eq "false" "$(gate_ok 'release authorised for HEAD')" "authorisation gate red"
assert_match 'does not exist' "$(gate_ev 'release authorised for HEAD')" "authorisation evidence says the marker is missing"

echo "-- (b) valid PASS, security Blocking 0, valid authorisation"
report "2026-09-03-$short.md" PASS "$head"
security 0 "2026-09-03-$short-security.md"
marker "$(( $(date +%s) + 7200 ))"
run
assert_eq "true" "$(gate_ok 'verification report PASS')" "verification gate green"
assert_match "2026-09-03-$short\.md" "$(gate_ev 'verification report PASS')" "verification evidence names the report"
assert_eq "true" "$(gate_ok 'security review without Blocking findings')" "security gate green"
assert_match 'Blocking: 0' "$(gate_ev 'security review without Blocking findings')" "security evidence shows the count"
assert_eq "true" "$(gate_ok 'release authorised for HEAD')" "authorisation gate green"
assert_eq "false" "$(jq -r .ready <<<"$OUT")" "ready stays false without a PR"

echo "-- (c) malformed security summary"
printf '# Security review\n\nBlocking: many  Important: 0\n' >"$V/2026-09-03-$short-security.md"
run
assert_eq "false" "$(gate_ok 'security review without Blocking findings')" "malformed Blocking line is a red gate"
assert_match 'malformed' "$(gate_ev 'security review without Blocking findings')" "evidence says malformed"
assert_not_match 'Blocking: 0' "$(gate_ev 'security review without Blocking findings')" "never read as zero findings"

echo "-- (d) security Blocking 2"
security 2 "2026-09-03-$short-security.md"
run
assert_eq "false" "$(gate_ok 'security review without Blocking findings')" "Blocking 2 is a red gate"
assert_match 'Blocking: 2' "$(gate_ev 'security review without Blocking findings')" "evidence shows the count"

echo "-- (d2) security report without a Commit line is valid with a warning"
printf '# Security review\n\nBlocking: 0  Important: 1  Nit: 0 (cap 5)\n' >"$V/2026-09-03-$short-security.md"
run
assert_eq "true" "$(gate_ok 'security review without Blocking findings')" "Commit line is optional in a security report"
assert_match 'no Commit line' "$(gate_ev 'security review without Blocking findings')" "evidence carries the warning"

echo "-- (d3) security report bound to another commit"
printf '# Security review\n**Commit:** 0123456789abcdef0123456789abcdef01234567\n\nBlocking: 0\n' >"$V/2026-09-03-$short-security.md"
run
assert_eq "false" "$(gate_ok 'security review without Blocking findings')" "security report for another commit is red"
assert_match 'not HEAD' "$(gate_ev 'security review without Blocking findings')" "evidence names the mismatch"
security 0 "2026-09-03-$short-security.md"

echo "-- (e) verification report for another commit"
report "2026-09-03-$short.md" PASS "0123456789abcdef0123456789abcdef01234567"
run
assert_eq "false" "$(gate_ok 'verification report PASS')" "PASS for another commit is red"
assert_match 'not HEAD' "$(gate_ev 'verification report PASS')" "evidence names the mismatch"

echo "-- (f) newer security report than the PASS report"
report "2026-09-03-$short.md" PASS "$head"
touch -t 202601010000 "$V/2026-09-03-$short.md"
security 0 "2026-09-04-$short-security.md"
run
assert_eq "true" "$(gate_ok 'verification report PASS')" "verification gate stays green"
assert_match "2026-09-03-$short\.md" "$(gate_ev 'verification report PASS')" "the normal report is the one named"
assert_eq "true" "$(gate_ok 'security review without Blocking findings')" "newest security report is used"

echo "-- (g) expired authorisation, dirty working tree"
marker "$(( $(date +%s) - 60 ))"
printf 'dirty\n' >"$proj/dirty.txt"
run
assert_eq "false" "$(gate_ok 'release authorised for HEAD')" "expired marker is red"
assert_match 'expired' "$(gate_ev 'release authorised for HEAD')" "evidence says expired"
assert_eq "false" "$(gate_ok 'working tree clean')" "dirty tree is red"
rm "$proj/dirty.txt"

echo "-- usage"
assert_exit 2 "unknown flag is a usage error" -- bash -c 'cd "$1" && bash "$2" --bogus' _ "$proj" "$pre"

eval_done
