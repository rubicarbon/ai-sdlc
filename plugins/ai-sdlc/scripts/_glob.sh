#!/usr/bin/env bash
# _glob.sh — gitignore-style glob matching with bash builtins.
#
#   sdlc_glob_match <pattern> <path>       exit 0 when the path matches
#   sdlc_glob_any   <path> <pattern>...    exit 0 when any pattern matches
#
# Rules (a subset of gitignore that covers hook configuration):
#   - paths are compared with forward slashes; a leading "./" is dropped
#   - a pattern without "/" matches the basename at any depth (`*.test.ts`)
#   - a pattern with "/" but no leading "/" matches at any depth (`secrets/**`, `tests/**/*.py`)
#   - a leading "/" anchors at the project root (`/CODEOWNERS`, `/.github/**`)
#   - `**` matches across directories, `*` within one segment, `?` one character
#   - a trailing "/" matches a directory prefix (`build/` == `build/**`)

sdlc__glob_to_ere() {
  local g="$1" out="" i c anchored=0 dir_self=""
  case "$g" in /*) anchored=1; g="${g#/}" ;; esac
  case "$g" in */) g="${g}**" ;; esac
  # `dir/**` also matches `dir` itself (a Grep or Glob aimed at the directory)
  case "$g" in */\*\*) g="${g%/\*\*}"; dir_self="(/.*)?" ;; esac
  local n=${#g}
  i=0
  while [ $i -lt $n ]; do
    c="${g:$i:1}"
    case "$c" in
      '*')
        if [ "${g:$i:2}" = '**' ]; then
          if [ "${g:$i:3}" = '**/' ]; then out="$out(.*/)?"; i=$((i+3)); continue; fi
          out="$out.*"; i=$((i+2)); continue
        fi
        out="${out}[^/]*" ;;
      '?') out="${out}[^/]" ;;
      '.'|'+'|'('|')'|'|'|'^'|'$'|'{'|'}'|'['|']'|'\\') out="$out\\$c" ;;
      *) out="$out$c" ;;
    esac
    i=$((i+1))
  done
  out="$out$dir_self"
  if [ $anchored = 1 ]; then
    printf '^%s$' "$out"
  else
    printf '^(.*/)?%s$' "$out"
  fi
}

sdlc_glob_match() {
  local pat="$1" path="$2" re
  path="${path//\\//}"; path="${path#./}"
  # strip an absolute project prefix when the caller passes one
  if [ -n "${SDLC_PROJECT_DIR:-}" ]; then
    local root="${SDLC_PROJECT_DIR//\\//}"
    case "$path" in "$root"/*) path="${path#"$root"/}" ;; esac
  fi
  re=$(sdlc__glob_to_ere "$pat")
  [[ "$path" =~ $re ]]
}

sdlc_glob_any() {
  local path="$1"; shift
  local p
  for p in "$@"; do sdlc_glob_match "$p" "$path" && return 0; done
  return 1
}
