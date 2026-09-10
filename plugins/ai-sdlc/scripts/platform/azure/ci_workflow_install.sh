#!/usr/bin/env bash
# ci_workflow_install (Azure DevOps): render the Azure Pipelines templates into
# .azuredevops/ and register each pipeline once. Idempotent. Under --dry-run the
# templates are rendered to temp files, the outcome is reported on stderr, the
# registration commands are printed and nothing is written into the repository.
set -u
export SDLC_PLATFORM=azure
. "${0%/*}/../../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/platform/_common.sh"
force=0; while [ $# -gt 0 ]; do case "$1" in --force) force=1 ;; *) usage_die "ci_workflow_install [--force]" ;; esac; shift; done
[ -n "${SDLC_PROJECT_DIR:-}" ] || sdlc_die 1 "no sdlc.config.json found: run /ai-sdlc:sdlc-init first"
require_az; az_context
tdir="${SDLC_CI_TEMPLATES_DIR:-$SDLC_PLUGIN_ROOT/templates}/azure"
[ -d "$tdir" ] || sdlc_die 1 "no Azure CI templates at $tdir"
default_branch=$(read_config '.repo.defaultBranch' 'main')
dry="${SDLC_DRY_RUN:-0}"

installed=(); unchanged=(); pending=(); registered=()
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
for t in "$tdir"/pipelines/*.yml; do
  [ -f "$t" ] || continue
  # review.runner local: the review pipeline is neither installed nor registered
  [ "$runner" = local ] && review_is_workflow "${t##*/}" && continue
  place "$t" ".azuredevops/pipelines/${t##*/}"
done
[ -f "$tdir/pull_request_template.md" ] && place "$tdir/pull_request_template.md" ".azuredevops/pull_request_template.md"

# Registration: a lookup failure is an error, never "not found" (that would register twice).
for t in "$tdir"/pipelines/*.yml; do
  [ -f "$t" ] || continue
  [ "$runner" = local ] && review_is_workflow "${t##*/}" && continue
  name="${t##*/}"; name="${name%.yml}"
  found=$(cli_json "az pipelines list --name $name" az pipelines list --name "$name" --repository "$AZ_REPO" \
    --repository-type tfsgit "${AZ_ARGS[@]}" -o json) || exit $?
  if [ "$(printf '%s' "$found" | jq -r 'if type=="array" then length else 0 end')" = "0" ]; then
    cli az pipelines create --name "$name" --yml-path ".azuredevops/pipelines/$name.yml" --repository "$AZ_REPO" \
      --repository-type tfsgit --branch "$default_branch" --skip-first-run true "${AZ_ARGS[@]}" -o json >/dev/null \
      || sdlc_die 1 "az pipelines create $name failed (push the rendered YAML to '$default_branch' first, then re-run)"
    registered+=("$name")
  fi
done

out_json "$(jq -cn --argjson i "$(json_list "${installed[@]+"${installed[@]}"}")" \
  --argjson u "$(json_list "${unchanged[@]+"${unchanged[@]}"}")" --argjson p "$(json_list "${pending[@]+"${pending[@]}"}")" \
  --argjson r "$(json_list "${registered[@]+"${registered[@]}"}")" \
  '{installed:$i, unchanged:$u, pending:$p, registered:$r, platform:"azure"}')"
