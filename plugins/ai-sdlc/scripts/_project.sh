#!/usr/bin/env bash
# _project.sh — locate the target project's sdlc.config.json. Source after _root.sh:
#
#   . "$SDLC_PLUGIN_ROOT/scripts/_project.sh"
#
# Walks up from $PWD (or $SDLC_CWD when set) to the git root or the filesystem
# root. When no sdlc.config.json is found:
#   - hooks (default): exits 0 immediately, so plugin hooks stay silent in
#     unrelated repositories. Bash builtins only, no process spawn.
#   - scripts that may run before init: set SDLC_PROJECT_OPTIONAL=1 to get
#     SDLC_PROJECT_DIR="" and continue.
# Exports SDLC_PROJECT_DIR, SDLC_CONFIG. Provides sdlc_config (lazy jq read) and
# SDLC_ARTIFACTS once the config is read.

sdlc__find_config() {  # -> SDLC_PROJECT_DIR (builtins only: no subshell on the silent path)
  local d="${SDLC_CWD:-$PWD}"
  SDLC_PROJECT_DIR=""
  d="${d//\\//}"
  if [[ "$d" =~ ^([A-Za-z]):(/.*)?$ ]]; then d="/${BASH_REMATCH[1],,}${BASH_REMATCH[2]}"; fi
  while :; do
    if [ -f "$d/sdlc.config.json" ]; then SDLC_PROJECT_DIR="$d"; return 0; fi
    { [ -d "$d/.git" ] || [ -f "$d/.git" ]; } && return 1     # repo root reached without a config
    case "$d" in */*) d="${d%/*}"; [ -z "$d" ] && return 1 ;; *) return 1 ;; esac
    [ "$d" = "/" ] && return 1
  done
}

sdlc__find_config || SDLC_PROJECT_DIR=""
if [ -z "$SDLC_PROJECT_DIR" ]; then
  if [ "${SDLC_PROJECT_OPTIONAL:-0}" = "1" ]; then
    SDLC_CONFIG=""
    export SDLC_PROJECT_DIR SDLC_CONFIG
    return 0 2>/dev/null || exit 0
  fi
  exit 0
fi
SDLC_CONFIG="$SDLC_PROJECT_DIR/sdlc.config.json"
export SDLC_PROJECT_DIR SDLC_CONFIG

# sdlc_config <jq filter> [default]  -> prints the value (raw) or the default.
# `false` is a real value here (jq's `//` would treat it as missing).
sdlc_config() {
  local v
  v=$(jq -r "$1 | if . == null then empty else . end" "$SDLC_CONFIG" 2>/dev/null)
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "${2:-}"; fi
}

# sdlc_artifacts_dir -> absolute artifacts directory (default .sdlc)
sdlc_artifacts_dir() {
  local rel; rel=$(sdlc_config '.artifacts.dir' '.sdlc')
  case "$rel" in /*) printf '%s' "$rel" ;; *) printf '%s' "$SDLC_PROJECT_DIR/$rel" ;; esac
}
