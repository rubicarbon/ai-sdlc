#!/usr/bin/env bash
# The build stage is gated on accepted (ready-for-agent), published tickets.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
pre="$P/scripts/loop/precondition.sh"

proj="$EVAL_TMP/proj"; mkdir -p "$proj"; git -C "$proj" init -q -b main
printf '{"version":1,"platform":"azure","tier":1,"artifacts":{"dir":".sdlc"}}' >"$proj/sdlc.config.json"

out=$(cd "$proj" && bash "$pre" build); rc=$?
assert_eq "2" "$rc" "no tickets: build blocked"
assert_match 'to-tickets' "$out" "no tickets: points at /mattpocock-skills:to-tickets"

mkdir -p "$proj/.sdlc/features/digest"; cp -r "$EVAL_ROOT/fixtures/feature-mock/." "$proj/.sdlc/features/digest/"
sed -i.bak 's/ready-for-agent/needs-triage/' "$proj/.sdlc/features/digest/issues/"*.md && rm -f "$proj/.sdlc/features/digest/issues/"*.bak
out=$(cd "$proj" && bash "$pre" build); rc=$?
assert_eq "2" "$rc" "tickets not accepted: build blocked"
assert_match 'none is .Status: ready-for-agent' "$out" "reason names the missing acceptance"

sed -i.bak 's/needs-triage/ready-for-agent/' "$proj/.sdlc/features/digest/issues/"*.md && rm -f "$proj/.sdlc/features/digest/issues/"*.bak
out=$(cd "$proj" && bash "$pre" build); rc=$?
assert_eq "2" "$rc" "accepted but unpublished on a real platform: build blocked"
assert_match 'sdlc-publish' "$out" "reason points at /ai-sdlc:sdlc-publish"

echo '{"spec":{"id":"1"},"tickets":{"01":{"id":"2"}},"links":[]}' >"$proj/.sdlc/features/digest/publish-manifest.json"
out=$(cd "$proj" && bash "$pre" build); rc=$?
assert_eq "0" "$rc" "accepted and published: build may start"

printf '{"version":1,"platform":"none","tier":1,"artifacts":{"dir":".sdlc"}}' >"$proj/sdlc.config.json"
rm "$proj/.sdlc/features/digest/publish-manifest.json"
out=$(cd "$proj" && bash "$pre" build); rc=$?
assert_eq "0" "$rc" "platform none: accepted local tickets are enough"

echo "-- ship stage: report selection and validation"
out=$(cd "$proj" && bash "$pre" ship); rc=$?
assert_eq "2" "$rc" "ship without a commit is blocked"
git -C "$proj" config user.email e@x; git -C "$proj" config user.name e
printf 'x\n' >"$proj/README.md"; ( cd "$proj" && git add -A >/dev/null && git commit -q -m init )
head=$(git -C "$proj" rev-parse HEAD); short="${head:0:7}"
V="$proj/.sdlc/verify"; mkdir -p "$V"
report() {  # report <name> <verdict> <commit> [extra lines...]
  local n="$1" v="$2" c="$3"; shift 3
  printf '# Verification: x\n\n**Verdict:** %s\n**Commit:** %s  **Base:** main  **Command:** `npm test` exit 0\n**Tree:** clean\n' "$v" "$c" >"$V/$n"
  for l in "$@"; do printf '%s\n' "$l" >>"$V/$n"; done
}
security() { printf '# Security review: x against main\n\nBlocking: %s  Important: 0  Nit: 0 (cap 5)\n' "$1" >"$V/$2"; }

out=$(cd "$proj" && bash "$pre" ship); rc=$?
assert_eq "2" "$rc" "ship without a verification report is blocked"
assert_match 'sdlc-verify' "$out" "reason points at /ai-sdlc:sdlc-verify"

security 0 "2026-09-03-$short-security.md"
out=$(cd "$proj" && bash "$pre" ship); rc=$?
assert_eq "2" "$rc" "a security-only verify directory is blocked"
assert_match 'no verification report' "$out" "security report is not mistaken for a verification report"
rm "$V/2026-09-03-$short-security.md"

report "2026-09-03-$short.md" PASS "$head"
out=$(cd "$proj" && bash "$pre" ship); rc=$?
assert_eq "0" "$rc" "valid PASS for HEAD may ship"
assert_match "2026-09-03-$short\.md" "$out" "success names the report"

touch -t 202601010000 "$V/2026-09-03-$short.md"
security 3 "2026-09-04-$short-security.md"
out=$(cd "$proj" && bash "$pre" ship); rc=$?
assert_eq "0" "$rc" "a newer security report is not selected as the verification report"
assert_match "2026-09-03-$short\.md" "$out" "the normal report is still the one named"
rm "$V/2026-09-04-$short-security.md"

report "2026-09-03-$short.md" PASS "0123456789abcdef0123456789abcdef01234567"
out=$(cd "$proj" && bash "$pre" ship); rc=$?
assert_eq "2" "$rc" "PASS report for another commit is blocked"
assert_match 'commit' "$out" "reason mentions the commit"

report "2026-09-03-$short.md" PASS "$head" "**Verdict:** FAIL"
out=$(cd "$proj" && bash "$pre" ship); rc=$?
assert_eq "2" "$rc" "two Verdict lines are blocked"
assert_match '2 Verdict lines' "$out" "reason counts the verdict lines"

printf '# Verification\n\n**Commit:** %s  **Base:** main\n' "$head" >"$V/2026-09-03-$short.md"
out=$(cd "$proj" && bash "$pre" ship); rc=$?
assert_eq "2" "$rc" "missing Verdict is blocked"
assert_match 'no .Verdict' "$out" "reason names the missing verdict"

printf '# Verification\n\n**Verdict:** PASS\n' >"$V/2026-09-03-$short.md"
out=$(cd "$proj" && bash "$pre" ship); rc=$?
assert_eq "2" "$rc" "PASS without a Commit line is blocked"
assert_match 'no .Commit' "$out" "reason names the missing commit line"

printf '# Verification\n\n**Verdict:** PASS\n**Commit:** %s\n' "$head" >"$V/2026-09-03-$short.md"
out=$(cd "$proj" && bash "$pre" ship); rc=$?
assert_eq "2" "$rc" "PASS without a Tree line is blocked"
assert_match 'verified tree is unknown' "$out" "reason says the verified tree is unknown"

: >"$V/2026-09-03-$short.md"
out=$(cd "$proj" && bash "$pre" ship); rc=$?
assert_eq "2" "$rc" "empty report is blocked"
assert_match 'empty' "$out" "reason says empty"

report "2026-09-03-$short.md" FAIL "$head"
out=$(cd "$proj" && bash "$pre" ship); rc=$?
assert_eq "2" "$rc" "FAIL report is blocked"
assert_match 'FAIL' "$out" "reason says FAIL"

report "2026-09-03-$short.md" PASS "$head"
out=$(cd "$proj" && bash "$pre" ship); rc=$?
assert_eq "0" "$rc" "valid PASS for HEAD may ship again"

echo "-- validate-report.sh"
vr="$P/scripts/loop/validate-report.sh"
assert_exit 0 "CLI: valid verification report" -- bash "$vr" "$V/2026-09-03-$short.md" --head "$head"
assert_exit 1 "CLI: verification report against another head" -- bash "$vr" "$V/2026-09-03-$short.md" --head 0123456789abcdef
security 0 "2026-09-03-$short-security.md"
assert_exit 0 "CLI: valid security report" -- bash "$vr" "$V/2026-09-03-$short-security.md" --security
assert_exit 1 "CLI: security report validated as a verification report" -- bash "$vr" "$V/2026-09-03-$short-security.md" --head "$head"
printf 'Blocking: many\n' >"$V/2026-09-03-$short-security.md"
assert_exit 1 "CLI: malformed Blocking line" -- bash "$vr" "$V/2026-09-03-$short-security.md" --security
assert_exit 2 "CLI: usage error" -- bash "$vr"

eval_done
