#!/usr/bin/env bash
# precondition.sh — does the artifact a stage needs exist? Used by sdlc-loop and
# sdlc-status to name the next stage, and by the ticket gate hook.
#
#   precondition.sh <stage> [--feature <slug>] [--pr <id>]   stages: spec tickets build verify ship
#
# Exit 0 when the stage may start, 2 when its input artifact is missing (reason on
# stdout as one line), 1 on error. Runs inside an sdlc project only. With review.runner
# local the ship stage also needs the PR-bound local review report for HEAD (selected by
# --pr or the current branch's mapping); with runner ci preflight.sh alone holds that gate.
set -u
. "${0%/*}/../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"
. "$SDLC_PLUGIN_ROOT/scripts/_project.sh"
. "$SDLC_PLUGIN_ROOT/scripts/loop/_reports.sh"
stage="${1:-}"; shift || true
feature=""; pr=""
while [ $# -gt 0 ]; do case "$1" in --feature) feature="$2"; shift 2 ;; --pr) pr="$2"; shift 2 ;; *) shift ;; esac; done
art=$(sdlc_artifacts_dir)

# feature directories: .sdlc/features/<slug>/ (ours) or .scratch/<slug>/ (their local tracker)
feature_dirs() {
  local d
  for d in "$art"/features/*/ "$SDLC_PROJECT_DIR"/.scratch/*/; do [ -d "$d" ] && printf '%s\n' "${d%/}"; done
}
pick_feature() {
  if [ -n "$feature" ]; then
    for d in "$art/features/$feature" "$SDLC_PROJECT_DIR/.scratch/$feature"; do [ -d "$d" ] && { printf '%s' "$d"; return 0; }; done
    return 1
  fi
  feature_dirs | head -n1
}

case "$stage" in
  spec)      echo "spec needs a framed conversation: run /ai-sdlc:sdlc-start first, then type /mattpocock-skills:to-spec"; exit 0 ;;
  tickets)
    d=$(pick_feature) && [ -f "$d/spec.md" ] && exit 0
    echo "no spec found (expected <feature>/spec.md under $art/features/ or .scratch/): type /mattpocock-skills:to-spec"; exit 2 ;;
  build)
    d=$(pick_feature); [ -n "$d" ] || { echo "no feature directory with tickets under $art/features/ or .scratch/: type /mattpocock-skills:to-tickets"; exit 2; }
    n=$(find "$d/issues" -maxdepth 1 -name '[0-9][0-9]-*.md' 2>/dev/null | wc -l | tr -d ' ')
    [ "${n:-0}" -gt 0 ] || { echo "no tickets under $d/issues/: type /mattpocock-skills:to-tickets"; exit 2; }
    ready=$(grep -liE '^\**Status:\**[[:space:]]*ready-for-agent' "$d"/issues/[0-9][0-9]-*.md 2>/dev/null | wc -l | tr -d ' ')
    [ "${ready:-0}" -gt 0 ] || { echo "tickets exist but none is 'Status: ready-for-agent' (accepted) in $d/issues/"; exit 2; }
    if [ -f "$SDLC_CONFIG" ] && [ "$(sdlc_config '.platform' none)" != none ] && [ ! -f "$d/publish-manifest.json" ]; then
      echo "tickets are not published to $(sdlc_config .platform) yet: run /ai-sdlc:sdlc-publish $d"; exit 2
    fi
    exit 0 ;;
  verify)
    git -C "$SDLC_PROJECT_DIR" rev-parse --verify HEAD >/dev/null 2>&1 || { echo "nothing committed yet"; exit 2; }
    exit 0 ;;
  ship)
    # verification reports only (never *-security.md), newest first; the newest report bound
    # to HEAD decides and must be a valid PASS (rules and reasons in scripts/loop/_reports.sh)
    head=$(git -C "$SDLC_PROJECT_DIR" rev-parse HEAD 2>/dev/null) || { echo "nothing committed yet: a verification report is bound to a commit"; exit 2; }
    report=$(sdlc_select_verify_report "$art/verify" "$head") || { echo "$report"; exit 2; }
    # review.runner local: the ship stage also needs the PR-bound local review for HEAD (the
    # CI comment does not exist there). With runner ci preflight.sh alone holds the security
    # gate, as before.
    runner=$(sdlc_config .review.runner ci); platform=$(sdlc_config .platform none)
    if [ "$runner" = local ]; then
      self=$(sdlc_tmpfile)
      sdlc_select_security_report "$art/verify" "$head" --runner local --platform "$platform" ${pr:+--pr "$pr"} >"$self" 2>/dev/null || { rm -f "$self"; echo "$SDLC_REPORT_REASON"; exit 2; }
      sec=$(<"$self"); rm -f "$self"
      [ "${SDLC_REPORT_BLOCKING:-1}" -eq 0 ] || { echo "security report ${sec##*/} has Blocking: $SDLC_REPORT_BLOCKING; fix the findings and review again"; exit 2; }
      echo "verification report ${report##*/} is a PASS for HEAD ${head:0:12}; local review ${sec##*/} has Blocking: 0"; exit 0
    fi
    echo "verification report ${report##*/} is a PASS for HEAD ${head:0:12}"; exit 0 ;;
  *) sdlc_die 1 "precondition.sh <spec|tickets|build|verify|ship>" ;;
esac
