#!/usr/bin/env bash
# ci_workflow_install (GitHub): render the GitHub CI templates into the repo.
# Idempotent: unchanged files are left alone; files that differ from the render
# are reported under "pending" (diff on stderr) unless --force. GitHub registers
# workflows automatically, so "registered" is always empty here. Under --dry-run the
# templates are rendered to temp files, the outcome is reported on stderr and nothing
# is written into the repository.
set -u
export SDLC_PLATFORM=github
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
force=0; while [ $# -gt 0 ]; do case "$1" in --force) force=1 ;; *) usage_die "ci_workflow_install [--force]" ;; esac; shift; done
[ -n "${SDLC_PROJECT_DIR:-}" ] || sdlc_die 1 "no sdlc.config.json found: run /ai-sdlc:sdlc-init first"
tdir="${SDLC_CI_TEMPLATES_DIR:-$SDLC_PLUGIN_ROOT/templates}/github"
[ -d "$tdir" ] || sdlc_die 1 "no GitHub CI templates at $tdir"
dry="${SDLC_DRY_RUN:-0}"

installed=(); unchanged=(); pending=()
place() {  # place <template> <dest-relative>
  local t="$1" dest="$SDLC_PROJECT_DIR/$2" rel="$2" tmp
  tmp=$(sdlc_tmpfile)
  bash "$SDLC_PLUGIN_ROOT/scripts/init/render.sh" "$t" --config "$SDLC_CONFIG" --out "$tmp" || { rm -f "$tmp"; sdlc_die 1 "rendering ${t##*/} failed"; }
  if [ ! -f "$dest" ]; then
    if [ "$dry" = 1 ]; then sdlc_log "dry-run: would install $rel"; rm -f "$tmp"
    else mkdir -p "${dest%/*}"; mv "$tmp" "$dest"; fi
    installed+=("$rel"); return
  fi
  if cmp -s "$tmp" "$dest"; then unchanged+=("$rel"); rm -f "$tmp"; [ "$dry" = 1 ] && sdlc_log "dry-run: $rel unchanged"; return; fi
  if [ $force = 1 ]; then
    if [ "$dry" = 1 ]; then sdlc_log "dry-run: would overwrite $rel"; rm -f "$tmp"; else mv "$tmp" "$dest"; fi
    installed+=("$rel"); return
  fi
  { echo "ai-sdlc: $rel differs from the current template (re-run with --force to overwrite):"; diff -u "$dest" "$tmp" | head -n 40; } >&2
  pending+=("$rel"); rm -f "$tmp"
}
runner=$(review_runner)
for t in "$tdir"/workflows/*.yml; do
  [ -f "$t" ] || continue
  # review.runner local: the review workflow and its cost report are not installed
  [ "$runner" = local ] && review_is_workflow "${t##*/}" && continue
  place "$t" ".github/workflows/${t##*/}"
done
[ -f "$tdir/PULL_REQUEST_TEMPLATE.md" ] && place "$tdir/PULL_REQUEST_TEMPLATE.md" ".github/PULL_REQUEST_TEMPLATE.md"
[ -f "$tdir/CODEOWNERS.tmpl" ] && place "$tdir/CODEOWNERS.tmpl" ".github/CODEOWNERS"

out_json "$(jq -cn --argjson i "$(json_list "${installed[@]+"${installed[@]}"}")" \
  --argjson u "$(json_list "${unchanged[@]+"${unchanged[@]}"}")" --argjson p "$(json_list "${pending[@]+"${pending[@]}"}")" \
  '{installed:$i, unchanged:$u, pending:$p, registered:[], platform:"github"}')"
