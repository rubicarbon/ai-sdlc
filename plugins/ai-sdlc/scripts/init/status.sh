#!/usr/bin/env bash
# status.sh — one JSON snapshot of the SDLC state of the current project for /sdlc-status.
#   status.sh [--repo-dir DIR]
set -u
. "${0%/*}/../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"
dir="$PWD"; while [ $# -gt 0 ]; do case "$1" in --repo-dir) dir="$2"; shift 2 ;; *) sdlc_die 2 "status.sh [--repo-dir DIR]" ;; esac; done
cd "$dir" || sdlc_die 2 "status.sh: cannot cd to $dir"
SDLC_PROJECT_OPTIONAL=1 . "$SDLC_PLUGIN_ROOT/scripts/_project.sh"
if [ -z "${SDLC_CONFIG:-}" ]; then jq -cn --arg d "$dir" '{initialised:false,dir:$d,hint:"run /ai-sdlc:sdlc-init"}'; exit 0; fi

valid=true; errors=$(bash "$SDLC_PLUGIN_ROOT/scripts/config/validate.sh" "$SDLC_CONFIG" --quiet 2>&1) || valid=false
drift=$(bash "$SDLC_PLUGIN_ROOT/scripts/init/run.sh" --check --repo-dir "$SDLC_PROJECT_DIR" 2>/dev/null || true); [ -n "$drift" ] || drift='{"result":"unknown","pending":[]}'
mp=$(bash "$SDLC_PLUGIN_ROOT/scripts/reuse/check-mattpocock.sh" --project "$SDLC_PROJECT_DIR" --json 2>/dev/null || true); [ -n "$mp" ] || mp='{"installed":false}'
art=$(sdlc_artifacts_dir)
pre='{}'
for stage in tickets build verify ship; do
  msg=$(bash "$SDLC_PLUGIN_ROOT/scripts/loop/precondition.sh" "$stage" 2>/dev/null); rc=$?
  pre=$(jq -c --arg s "$stage" --argjson ok "$([ $rc -eq 0 ] && echo true || echo false)" --arg m "$msg" '.[$s]={ready:$ok,reason:(if $m=="" then null else $m end)}' <<<"$pre")
done
auth=$(ls "$art"/release/AUTHORIZED-* 2>/dev/null | sed 's|.*/AUTHORIZED-||' | jq -R . | jq -cs .)
features=$(for feature in "$art"/features/*/; do [ -d "$feature" ] && basename "${feature%/}"; done | jq -R . | jq -cs .)
verify_reports=$(ls "$art"/verify/*.md 2>/dev/null | wc -l | tr -d ' ')
# local review runner: launches that have not ended, retired review files still present, and
# whether the remote side of a runner switch is still pending (scripts/review/status.sh,
# <artifacts>/migrations.json)
runner=$(sdlc_config .review.runner ci)
launches='[]'
if [ -d "$art/tmp/review" ]; then
  all=$(bash "$SDLC_PLUGIN_ROOT/scripts/review/status.sh" get --all 2>/dev/null || echo '[]')
  launches=$(jq -c --arg p "$(sdlc_config .platform none)" '[.[] | select((.state | IN("posted","stale","abandoned","timeout") | not) and ((.state | startswith("failed")) | not) and ((.state | startswith("skipped")) | not) and (($p == "none" and .state == "saved") | not)) | {launch_id, pr, branch, state, detail, head_sha}]' <<<"$all" 2>/dev/null || echo '[]')
fi
retire_pending=$(jq -c '[.files[]? | select(.status == "retire-pending") | .path]' <<<"$drift" 2>/dev/null || echo '[]')
migration_pending=false
[ -f "$art/migrations.json" ] && jq -e '.["review-runner"].remote == "pending"' "$art/migrations.json" >/dev/null 2>&1 && migration_pending=true
jq -cn --arg dir "$SDLC_PROJECT_DIR" --argjson valid "$valid" --arg errors "$errors" \
  --arg platform "$(sdlc_config .platform none)" --argjson tier "$(sdlc_config .tier 0)" --arg team "$(sdlc_config .team.mode solo)" --arg verify "$(sdlc_config .commands.verify '')" \
  --arg pv "$(sdlc_config .pluginVersion unknown)" --arg cur "$SDLC_PLUGIN_VERSION" \
  --argjson drift "$drift" --argjson mp "$mp" --argjson pre "$pre" --argjson auth "$auth" --argjson features "$features" --argjson vr "$verify_reports" \
  --arg runner "$runner" --argjson launches "$launches" --argjson rp "$retire_pending" --argjson mig "$migration_pending" '
  {initialised:true, dir:$dir, config:{valid:$valid, errors:(if $errors=="" then [] else ($errors|split("\n")) end), platform:$platform, tier:$tier, team:$team, verify:$verify, renderedBy:$pv, pluginVersion:$cur, upgradeAvailable:($pv != $cur)},
   drift:{result:$drift.result, pending:$drift.pending}, mattpocock:$mp, stages:$pre,
   releaseAuthorisations:$auth, features:$features, verifyReports:$vr,
   review:{runner:$runner, launches:$launches, retirePending:$rp, migrationPending:$mig}}'
