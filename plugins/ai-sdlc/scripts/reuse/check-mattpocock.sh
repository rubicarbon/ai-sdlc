#!/usr/bin/env bash
# check-mattpocock.sh — is mattpocock-skills installed, and does it still match the
# routing table that sdlc-loop was written against?
#
#   check-mattpocock.sh [--plugin-root <dir>] [--project <dir>] [--json]
#
# Exit 0: installed and every routed skill present with the expected invocation type.
# Exit 1: installed but drifted (skills missing, renamed, or re-typed); details printed.
# Exit 2: not installed (no cache entry, or --plugin-root does not hold the plugin).
# Also warns about editable copies (`npx skills add mattpocock/skills`) in the project:
# running both routes duplicates every skill.
set -u
. "${0%/*}/../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"
manifest="$SDLC_PLUGIN_ROOT/scripts/reuse/mattpocock-manifest.json"

root=""; project="${PWD}"; as_json=0
while [ $# -gt 0 ]; do
  case "$1" in
    --plugin-root) root="$2"; shift 2 ;;
    --project) project="$2"; shift 2 ;;
    --json) as_json=1; shift ;;
    *) sdlc_die 2 "check-mattpocock.sh [--plugin-root <dir>] [--project <dir>] [--json]" ;;
  esac
done

find_installed() {
  local base="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache" d best=""
  for d in "$base"/*/mattpocock-skills/*/; do
    d="${d%/}"; [ -f "$d/.claude-plugin/plugin.json" ] || continue
    if [ -z "$best" ]; then best="$d"; else case "$(ls -td "$best" "$d" 2>/dev/null | head -n1)" in "$d") best="$d" ;; esac; fi
  done
  [ -n "$best" ] && printf '%s' "$best"
}
[ -n "$root" ] || root=$(find_installed)

# editable copies in the project (skills.sh route)
editable=()
for cand in "$project/.claude/skills" "$project/.agents/skills" "$project/skills"; do
  [ -d "$cand" ] || continue
  for s in "$cand"/*/SKILL.md; do
    [ -f "$s" ] || continue
    n=$(sed -n 's/^name:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' "$s" | head -n1)
    [ -n "$n" ] && jq -e --arg n "$n" '.skills[$n] != null' "$manifest" >/dev/null 2>&1 && editable+=("${s#"$project"/}")
  done
done

if [ -z "$root" ] || [ ! -f "$root/.claude-plugin/plugin.json" ]; then
  if [ $as_json = 1 ]; then jq -cn --argjson e "$(printf '%s\n' "${editable[@]+"${editable[@]}"}" | jq -R . | jq -cs 'map(select(length>0))')" '{installed:false,editable_copies:$e}'
  else
    echo "mattpocock-skills: NOT installed. Install with: /plugin install mattpocock-skills (official marketplace)"
    [ ${#editable[@]} -gt 0 ] && printf 'editable copy present (skills.sh route): %s\n' "${editable[@]}"
  fi
  exit 2
fi

installed_version=$(jq -r '.version // "unknown"' "$root/.claude-plugin/plugin.json")
expected_version=$(jq -r .version "$manifest")
missing=(); retyped=(); added=()
while IFS=$'\t' read -r name expected; do
  path=$(jq -r --arg n "$name" '.skills[] | select(endswith("/"+$n))' "$root/.claude-plugin/plugin.json" | head -n1)
  if [ -z "$path" ] || [ ! -f "$root/${path#./}/SKILL.md" ]; then missing+=("$name"); continue; fi
  if grep -qE '^disable-model-invocation:[[:space:]]*(true|yes|on|1)' "$root/${path#./}/SKILL.md"; then actual=user; else actual=model; fi
  [ "$actual" = "$expected" ] || retyped+=("$name: expected $expected-invoked, now $actual-invoked")
done < <(jq -r '.skills | to_entries[] | "\(.key)\t\(.value)"' "$manifest")
while IFS= read -r p; do
  n="${p##*/}"; jq -e --arg n "$n" '.skills[$n] != null' "$manifest" >/dev/null || added+=("$n")
done < <(jq -r '.skills[]' "$root/.claude-plugin/plugin.json")

drift=0; [ ${#missing[@]} -gt 0 ] || [ ${#retyped[@]} -gt 0 ] && drift=1
routed_missing=0
for m in "${missing[@]+"${missing[@]}"}"; do jq -e --arg m "$m" '.routed | index($m) != null' "$manifest" >/dev/null && routed_missing=1; done

j() { printf '%s\n' "$@" | jq -R . | jq -cs 'map(select(length>0))'; }
if [ $as_json = 1 ]; then
  jq -cn --arg root "$root" --arg iv "$installed_version" --arg ev "$expected_version" --argjson m "$(j "${missing[@]+"${missing[@]}"}")" --argjson r "$(j "${retyped[@]+"${retyped[@]}"}")" --argjson a "$(j "${added[@]+"${added[@]}"}")" --argjson e "$(j "${editable[@]+"${editable[@]}"}")" --argjson d "$drift" \
    '{installed:true,root:$root,installed_version:$iv,expected_version:$ev,missing:$m,retyped:$r,added:$a,editable_copies:$e,drift:($d==1)}'
else
  echo "mattpocock-skills $installed_version at $root (sdlc-loop written against $expected_version, commit $(jq -r .commit "$manifest" | cut -c1-7))"
  [ ${#missing[@]} -gt 0 ] && printf 'MISSING skill: %s\n' "${missing[@]}"
  [ ${#retyped[@]} -gt 0 ] && printf 'RETYPED skill: %s\n' "${retyped[@]}"
  [ ${#added[@]} -gt 0 ] && printf 'new upstream skill not in the routing table: %s\n' "${added[@]}"
  [ ${#editable[@]} -gt 0 ] && printf 'WARNING editable copy present (skills.sh route): %s (every skill is now loaded twice)\n' "${editable[@]}"
  if [ $drift = 1 ]; then echo "DRIFT: sdlc-loop's routing table is stale; review docs/REUSE.md and skills/sdlc-loop/SKILL.md"; [ $routed_missing = 1 ] && echo "at least one skill that sdlc-loop routes to is gone"; else echo "OK: routing table matches the installed plugin"; fi
fi
[ $drift = 0 ]
