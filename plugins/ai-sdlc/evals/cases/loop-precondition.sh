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

out=$(cd "$proj" && bash "$pre" ship); rc=$?
assert_eq "2" "$rc" "ship without a verification report is blocked"
mkdir -p "$proj/.sdlc/verify"; printf '# Verification\n\n**Verdict:** PASS\n' >"$proj/.sdlc/verify/2026-09-03-abc.md"
out=$(cd "$proj" && bash "$pre" ship); rc=$?
assert_eq "0" "$rc" "ship with a PASS report may start"

eval_done
