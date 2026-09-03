#!/usr/bin/env bash
# render.sh — render one template with {{VARIABLE}} markers from sdlc.config.json.
#
#   render.sh <template-file> [--config sdlc.config.json] [--var NAME=value]... [--out file] [--check]
#
# Variables come from the config, flattened: repo.defaultBranch -> REPO_DEFAULT_BRANCH,
# cost.maxTurns -> COST_MAX_TURNS. Arrays are exposed twice: NAME (comma-joined) and
# NAME_JSON. Derived variables: PLUGIN_VERSION, PLUGIN_ID, MARKETPLACE_REPO, DATE,
# PROJECT_NAME. --var overrides everything. Any {{MARKER}} left unresolved is an
# error (exit 1) that lists the markers, so a placeholder can never reach a repo.
# --check prints "same" / "differs" / "missing" against --out instead of writing.
set -u
. "${0%/*}/../_root.sh" || exit 2
. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"

tmpl=""; cfg=""; out=""; check=0
declare -a overrides=()
while [ $# -gt 0 ]; do
  case "$1" in
    --config) cfg="$2"; shift 2 ;;
    --var) overrides+=("$2"); shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --check) check=1; shift ;;
    -*) sdlc_die 2 "render.sh: unknown option $1" ;;
    *) tmpl="$1"; shift ;;
  esac
done
[ -n "$tmpl" ] && [ -f "$tmpl" ] || sdlc_die 2 "render.sh: template file required"
if [ -z "$cfg" ]; then
  SDLC_PROJECT_OPTIONAL=1 . "$SDLC_PLUGIN_ROOT/scripts/_project.sh"
  cfg="${SDLC_CONFIG:-}"
fi

content=$(<"$tmpl")

# Flatten the config into NAME=value lines.
declare -A vars=()
if [ -n "$cfg" ] && [ -f "$cfg" ]; then
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] && vars["$k"]="$v"
  done < <(jq -r '
    def upsnake: gsub("(?<a>[a-z0-9])(?<b>[A-Z])"; "\(.a)_\(.b)") | ascii_upcase | gsub("\\."; "_");
    [paths(scalars) as $p | {k: ($p | map(tostring) | join(".") | upsnake), v: (getpath($p) | tostring)}]
    + [paths(type == "array") as $p | {k: ($p | map(tostring) | join(".") | upsnake), v: (getpath($p) | map(tostring) | join(","))}]
    + [paths(type == "array") as $p | {k: (($p | map(tostring) | join(".") | upsnake) + "_JSON"), v: (getpath($p) | tojson)}]
    | .[] | select(.k | test("^[A-Z0-9_]+$")) | "\(.k)\t\(.v)"' "$cfg")
  vars[PROJECT_NAME]="${vars[REPO_NAME]:-${cfg%/sdlc.config.json}}"; vars[PROJECT_NAME]="${vars[PROJECT_NAME]##*/}"
fi
vars[PLUGIN_VERSION]="$SDLC_PLUGIN_VERSION"
vars[PLUGIN_ID]="ai-sdlc@ai-sdlc-kit"
vars[MARKETPLACE_REPO]="gergely-somogyvari/ai-sdlc-kit"
vars[DATE]=$(sdlc_today)
for o in "${overrides[@]+"${overrides[@]}"}"; do vars["${o%%=*}"]="${o#*=}"; done

for k in "${!vars[@]}"; do
  content="${content//"{{$k}}"/"${vars[$k]}"}"
done

left=$(printf '%s' "$content" | grep -o '{{[A-Z0-9_]*}}' | sort -u | paste -sd' ' 2>/dev/null || true)
if [ -n "$left" ]; then
  sdlc_die 1 "render.sh: unresolved markers in ${tmpl##*/}: $left (add them to sdlc.config.json or pass --var)"
fi

if [ -n "$out" ]; then
  if [ "$check" = 1 ]; then
    if [ ! -f "$out" ]; then echo missing
    elif [ "$(<"$out")" = "$content" ]; then echo same
    else echo differs; fi
    exit 0
  fi
  mkdir -p "${out%/*}" 2>/dev/null || true
  printf '%s\n' "$content" > "$out"
else
  printf '%s\n' "$content"
fi
