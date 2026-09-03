#!/usr/bin/env bash
# merge-settings.sh — merge JSON fragments into a settings file without clobbering.
#
#   merge-settings.sh <target.json> <fragment.json>... [--dry-run]
#
# Objects merge recursively, arrays become the union (existing entries first, new unique
# entries appended), and a scalar already present in the target is kept. The target is
# created when missing. Prints {"target","changed"}; with --dry-run prints the merged JSON.
set -u
. "${0%/*}/../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"

target=""; frags=(); dry=0
while [ $# -gt 0 ]; do
  case "$1" in --dry-run) dry=1; shift ;; -*) sdlc_die 2 "merge-settings.sh <target.json> <fragment.json>... [--dry-run]" ;; *) if [ -z "$target" ]; then target="$1"; else frags+=("$1"); fi; shift ;; esac
done
[ -n "$target" ] && [ ${#frags[@]} -gt 0 ] || sdlc_die 2 "merge-settings.sh <target.json> <fragment.json>... [--dry-run]"
for f in "${frags[@]}"; do jq -e . "$f" >/dev/null 2>&1 || sdlc_die 2 "merge-settings.sh: $f is not valid JSON"; done

if [ -f "$target" ]; then
  jq -e . "$target" >/dev/null 2>&1 || sdlc_die 1 "merge-settings.sh: $target exists but is not valid JSON; fix it by hand first"
  base=$(<"$target")
else base='{}'; fi

merged="$base"
for f in "${frags[@]}"; do
  merged=$(jq -c --argjson add "$(<"$f")" '
    def merge($a; $b):
      if ($a | type) == "object" and ($b | type) == "object" then
        reduce ($b | keys[]) as $k ($a; .[$k] = (if ($a | has($k)) then merge($a[$k]; $b[$k]) else $b[$k] end))
      elif ($a | type) == "array" and ($b | type) == "array" then
        $a + [ $b[] as $x | select(($a | index([$x])) == null) | $x ]
      else $a end;
    merge(.; $add)' <<<"$merged") || sdlc_die 1 "merge-settings.sh: merging $f failed"
done

pretty=$(jq . <<<"$merged")
if [ $dry = 1 ]; then printf '%s\n' "$pretty"; exit 0; fi
changed=false
if [ ! -f "$target" ] || [ "$(jq -c . "$target")" != "$(jq -c . <<<"$merged")" ]; then
  mkdir -p "$(dirname "$target")"
  printf '%s\n' "$pretty" >"$target"; changed=true
fi
jq -cn --arg t "$target" --argjson c "$changed" '{target:$t,changed:$c}'
