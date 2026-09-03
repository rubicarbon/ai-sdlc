#!/usr/bin/env bash
# _root.sh — resolve the plugin root. Source this first in every hook and script:
#
#   . "${0%/*}/../scripts/_root.sh" || exit 2
#
# Sets and exports SDLC_PLUGIN_ROOT (absolute, forward slashes) and
# SDLC_PLUGIN_VERSION. Resolution order:
#   1. $CLAUDE_PLUGIN_ROOT when set, non-empty and it contains .claude-plugin/plugin.json
#   2. this file's own location (<root>/scripts/_root.sh)
#   3. the newest ai-sdlc entry in the Claude plugin cache
# It never yields "/" or an empty string: on failure it prints a clear message
# and returns 1 so the caller can decide whether that blocks (exit 2) or not.
#
# Claude Code issues #42564 and #66557 document sessions where CLAUDE_PLUGIN_ROOT
# was unset or unexpanded; steps 2 and 3 exist for those clients.
#
# Bash builtins only on the happy path: every $(...) is a fork, and a fork costs
# 30-150 ms on Windows. Helpers return through variables instead of stdout.

sdlc__norm() {  # sdlc__norm <path> -> SDLC__N : backslashes to slashes, C: to /c
  local p="$1"
  p="${p//\\//}"
  if [[ "$p" =~ ^([A-Za-z]):(/.*)?$ ]]; then p="/${BASH_REMATCH[1],,}${BASH_REMATCH[2]}"; fi
  SDLC__N="$p"
}

sdlc__is_root() {  # a plugin root has a manifest whose name is ai-sdlc
  [ -n "$1" ] && [ "$1" != "/" ] && [ -f "$1/.claude-plugin/plugin.json" ] || return 1
  local m; m=$(<"$1/.claude-plugin/plugin.json")
  [[ "$m" =~ \"name\"[[:space:]]*:[[:space:]]*\"ai-sdlc\" ]]
}

sdlc__root_from_self() {  # -> SDLC__CAND
  local self="${BASH_SOURCE[0]}" dir
  case "$self" in /*|[A-Za-z]:*|\\*) ;; *) self="$PWD/$self" ;; esac
  sdlc__norm "$self"; self="$SDLC__N"
  # canonicalise first: callers source this file through paths like hooks/../scripts/_root.sh
  local IFS='/' s r="" ; local -a parts out=()
  read -ra parts <<<"$self"
  for s in "${parts[@]}"; do
    case "$s" in ''|'.') ;; '..') [ ${#out[@]} -gt 0 ] && { unset 'out[${#out[@]}-1]'; out=("${out[@]}"); } ;; *) out+=("$s") ;; esac
  done
  for s in "${out[@]}"; do r="$r/$s"; done
  dir="${r%/*}"             # <root>/scripts
  dir="${dir%/*}"           # <root>
  SDLC__CAND="$dir"
}

sdlc__root_from_cache() {  # -> SDLC__CAND (may be empty). Fallback only; may spawn ls.
  local base="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache" d best=""
  SDLC__CAND=""
  [ -d "$base" ] || return 1
  for d in "$base"/*/ai-sdlc/*/; do
    d="${d%/}"
    sdlc__is_root "$d" || continue
    if [ -z "$best" ]; then best="$d"
    else
      # newest directory wins (ls -td is portable across GNU and BSD)
      case "$(ls -td "$best" "$d" 2>/dev/null | head -n1)" in "$d") best="$d" ;; esac
    fi
  done
  [ -n "$best" ] || return 1
  sdlc__norm "$best"; SDLC__CAND="$SDLC__N"
}

sdlc_resolve_root() {
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    sdlc__norm "$CLAUDE_PLUGIN_ROOT"
    if sdlc__is_root "$SDLC__N"; then SDLC_PLUGIN_ROOT="$SDLC__N"; SDLC_ROOT_SOURCE="CLAUDE_PLUGIN_ROOT"; return 0; fi
    echo "ai-sdlc: CLAUDE_PLUGIN_ROOT='$CLAUDE_PLUGIN_ROOT' is not an ai-sdlc plugin root; falling back to script location" >&2
  fi
  sdlc__root_from_self
  if sdlc__is_root "$SDLC__CAND"; then SDLC_PLUGIN_ROOT="$SDLC__CAND"; SDLC_ROOT_SOURCE="script-path"; return 0; fi
  if sdlc__root_from_cache && sdlc__is_root "$SDLC__CAND"; then SDLC_PLUGIN_ROOT="$SDLC__CAND"; SDLC_ROOT_SOURCE="plugin-cache"; return 0; fi
  echo "ai-sdlc: cannot locate the plugin root. CLAUDE_PLUGIN_ROOT is '${CLAUDE_PLUGIN_ROOT:-<unset>}', this script lives at '${BASH_SOURCE[0]}', and no ai-sdlc entry was found under '${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache'. Reinstall with: /plugin install ai-sdlc@ai-sdlc-kit" >&2
  return 1
}

sdlc_resolve_root || return 1 2>/dev/null || exit 1

SDLC_PLUGIN_VERSION="unknown"
sdlc__manifest=$(<"$SDLC_PLUGIN_ROOT/.claude-plugin/plugin.json")
if [[ "$sdlc__manifest" =~ \"version\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
  SDLC_PLUGIN_VERSION="${BASH_REMATCH[1]}"
fi
unset sdlc__manifest
export SDLC_PLUGIN_ROOT SDLC_PLUGIN_VERSION SDLC_ROOT_SOURCE
