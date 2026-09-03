#!/usr/bin/env bash
# _lib.sh — small portable helpers shared by scripts and adapters.
# POSIX-friendly bash: no GNU-only flags (no `sed -i`, `date -d`, `realpath -m`, `readlink -f`).

# Windows builds of jq end every output line with CRLF. `$(...)` happens to drop the CR,
# `while read` loops and files do not, so every jq call goes through binary mode there.
case "${OSTYPE:-}" in msys*|cygwin*|win32*) jq() { command jq -b "$@"; } ;; esac

sdlc_die() {   # sdlc_die [exit-code] message...
  local code=1
  case "${1:-}" in ''|*[!0-9]*) ;; *) code="$1"; shift ;; esac
  echo "ai-sdlc: $*" >&2
  exit "$code"
}

sdlc_log() { [ "${SDLC_QUIET:-0}" = "1" ] || echo "ai-sdlc: $*" >&2; }

sdlc_has() { command -v "$1" >/dev/null 2>&1; }

sdlc_require() {  # sdlc_require cmd [hint]
  sdlc_has "$1" || sdlc_die 1 "required command '$1' not found. ${2:-}"
}

sdlc_norm_path() {  # backslashes to slashes, C: to /c
  local p="$1"
  p="${p//\\//}"
  if [[ "$p" =~ ^([A-Za-z]):(/.*)?$ ]]; then p="/${BASH_REMATCH[1],,}${BASH_REMATCH[2]}"; fi
  printf '%s' "$p"
}

sdlc_abs_path() {  # make a path absolute against $PWD, lexically
  local p; p=$(sdlc_norm_path "$1")
  case "$p" in /*) ;; *) p="$(sdlc_norm_path "$PWD")/$p" ;; esac
  local IFS='/' s r=""; local -a parts out=()
  read -ra parts <<<"$p"
  for s in "${parts[@]}"; do
    case "$s" in ''|'.') ;; '..') [ ${#out[@]} -gt 0 ] && { unset 'out[${#out[@]}-1]'; out=("${out[@]}"); } ;; *) out+=("$s") ;; esac
  done
  for s in "${out[@]}"; do r="$r/$s"; done
  printf '%s' "${r:-/}"
}

# sdlc_python -> prints a Python 3 interpreter that actually runs. On Windows `python3` is often
# the Microsoft Store stub, which exists on PATH but only prints an install hint, so each
# candidate is executed rather than merely looked up.
sdlc_python() {
  local c
  for c in python3 python py; do
    if "$c" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then printf '%s' "$c"; return 0; fi
  done
  return 1
}

# sdlc_sha256 <file> -> hex digest (sha256sum on Linux/Git Bash, shasum on macOS, openssl as fallback)
sdlc_sha256() {
  if sdlc_has sha256sum; then sha256sum "$1" | cut -d' ' -f1
  elif sdlc_has shasum; then shasum -a 256 "$1" | cut -d' ' -f1
  elif sdlc_has openssl; then openssl dgst -sha256 "$1" | sed 's/^.*= //'
  else cksum "$1" | cut -d' ' -f1; fi
}

sdlc_iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
sdlc_today()   { date -u +%Y-%m-%d; }

sdlc_tmpfile() {  # sdlc_tmpfile [suffix] -> path inside the project or $TMPDIR
  local dir="${SDLC_TMPDIR:-${TMPDIR:-/tmp}}" f
  f=$(mktemp "$dir/ai-sdlc.XXXXXX") || sdlc_die 1 "cannot create a temp file in $dir"
  if [ -n "${1:-}" ]; then mv "$f" "$f$1"; f="$f$1"; fi
  printf '%s' "$f"
}

sdlc_json_escape() {  # escape a string for inclusion in JSON (no jq spawn)
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

sdlc_lower() { printf '%s' "${1,,}"; }

# sdlc_replace_in_file <file> <search> <replace> : portable in-place literal replace
sdlc_replace_in_file() {
  local f="$1" s="$2" r="$3" tmp content
  content=$(<"$f")
  tmp="$f.tmp.$$"
  printf '%s\n' "${content//"$s"/"$r"}" > "$tmp" && mv "$tmp" "$f"
}
