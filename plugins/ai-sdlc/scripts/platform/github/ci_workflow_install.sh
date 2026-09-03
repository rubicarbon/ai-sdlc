#!/usr/bin/env bash
# ci_workflow_install (GitHub): render the GitHub CI templates into the repo.
# Idempotent: unchanged files are left alone; files that differ from the render
# are reported under "pending" (diff on stderr) unless --force. GitHub registers
# workflows automatically, so "registered" is always empty here.
set -u
export SDLC_PLATFORM=github
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
force=0; while [ $# -gt 0 ]; do case "$1" in --force) force=1 ;; *) usage_die "ci_workflow_install [--force]" ;; esac; shift; done
[ -n "${SDLC_PROJECT_DIR:-}" ] || sdlc_die 1 "no sdlc.config.json found: run /ai-sdlc:sdlc-init first"
tdir="${SDLC_CI_TEMPLATES_DIR:-$SDLC_PLUGIN_ROOT/templates}/github"
[ -d "$tdir" ] || sdlc_die 1 "no GitHub CI templates at $tdir"

installed=(); unchanged=(); pending=()
place() {  # place <template> <dest-relative>
  local t="$1" dest="$SDLC_PROJECT_DIR/$2" rel="$2" state tmp
  tmp=$(sdlc_tmpfile)
  bash "$SDLC_PLUGIN_ROOT/scripts/init/render.sh" "$t" --config "$SDLC_CONFIG" --out "$tmp" || { rm -f "$tmp"; sdlc_die 1 "rendering ${t##*/} failed"; }
  if [ ! -f "$dest" ]; then mkdir -p "${dest%/*}"; mv "$tmp" "$dest"; installed+=("$rel"); return; fi
  if cmp -s "$tmp" "$dest"; then unchanged+=("$rel"); rm -f "$tmp"; return; fi
  if [ $force = 1 ]; then mv "$tmp" "$dest"; installed+=("$rel"); return; fi
  { echo "ai-sdlc: $rel differs from the current template (re-run with --force to overwrite):"; diff -u "$dest" "$tmp" | head -n 40; } >&2
  pending+=("$rel"); rm -f "$tmp"
}
for t in "$tdir"/workflows/*.yml; do [ -f "$t" ] && place "$t" ".github/workflows/${t##*/}"; done
[ -f "$tdir/PULL_REQUEST_TEMPLATE.md" ] && place "$tdir/PULL_REQUEST_TEMPLATE.md" ".github/PULL_REQUEST_TEMPLATE.md"
[ -f "$tdir/CODEOWNERS.tmpl" ] && place "$tdir/CODEOWNERS.tmpl" ".github/CODEOWNERS"

j() { printf '%s\n' "$@" | jq -R . | jq -cs 'map(select(length>0))'; }
out_json "$(jq -cn --argjson i "$(j "${installed[@]+"${installed[@]}"}")" --argjson u "$(j "${unchanged[@]+"${unchanged[@]}"}")" --argjson p "$(j "${pending[@]+"${pending[@]}"}")" '{installed:$i,unchanged:$u,pending:$p,registered:[],platform:"github"}')"
