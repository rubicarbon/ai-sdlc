#!/usr/bin/env bash
# guard-repo-boundary.sh
#
# PreToolUse hook for THIS development repo (not part of the shipped plugin).
# Denies any tool call whose target path resolves outside the repo root:
# file tools (Read/Edit/Write/NotebookEdit/Glob/Grep) and shell tools
# (Bash/PowerShell), including cd out of the tree, `..` traversal, symlinks
# pointing outward, Windows drive paths, home/temp variables and
# `git -C` / `git worktree` with external paths.
#
# Exit 2 = deny (reason on stderr). Exit 0 = no opinion.
#
# Performance note: process spawns cost 30-100 ms each under MSYS, so this
# script uses bash builtins only, plus one jq call and realpath only when a
# path component is actually a symlink.
set -u

deny() {
  echo "BLOCKED by repo boundary hook: $1" >&2
  echo "Allowed root: $REPO_ROOT. Ask the user to bring external material into the repo instead." >&2
  exit 2
}

# norm <path>  -> R_NORM : backslashes to slashes, drive letters to /c form.
norm() {
  local p="$1"
  p="${p//\\//}"
  if [[ "$p" =~ ^([A-Za-z]):(/.*)?$ ]]; then
    p="/${BASH_REMATCH[1],,}${BASH_REMATCH[2]}"
  fi
  R_NORM="$p"
}

# canon <abs-path> -> R_CANON : collapse . and .. lexically.
canon() {
  local IFS='/' s r=""
  local -a parts out=()
  read -ra parts <<<"$1"
  for s in "${parts[@]}"; do
    case "$s" in
      ''|'.') ;;
      '..') if [ ${#out[@]} -gt 0 ]; then unset 'out[${#out[@]}-1]'; out=("${out[@]}"); fi ;;
      *) out+=("$s") ;;
    esac
  done
  for s in "${out[@]}"; do r="$r/$s"; done
  R_CANON="${r:-/}"
}

inside() {
  local p="${1,,}"
  [[ "$p" == "$ROOT_LC" || "$p" == "$ROOT_LC/"* ]]
}

# Repo root from this script's own location (builtins only: no cd/pwd subshell).
case "$0" in /*) s0="$0" ;; *) s0="$PWD/$0" ;; esac
norm "$s0"; canon "${R_NORM%/*}/../.."; REPO_ROOT="$R_CANON"
ROOT_LC="${REPO_ROOT,,}"

if [ -e "$REPO_ROOT/.dev/BOUNDARY_HOOK_DISABLED" ]; then
  echo "WARNING: repo boundary hook is DISABLED by .dev/BOUNDARY_HOOK_DISABLED (delete it to re-arm)" >&2
  exit 0
fi

# Read stdin with a builtin (no `cat` spawn); one jq call extracts every field.
# Fail closed: unparseable input denies the call instead of silently allowing it.
IFS= read -r -d '' input || true
parsed=$(jq -r '@sh "tool=\(.tool_name // "") cwd=\(.cwd // "") fp=\(.tool_input.file_path // "") nb=\(.tool_input.notebook_path // "") gp=\(.tool_input.path // "") cmd=\(.tool_input.command // "")"' <<<"$input" 2>/dev/null) \
  || deny "hook input is not valid JSON; refusing to guess"
[ -n "$parsed" ] || deny "hook input is empty; refusing to guess"
eval "$parsed"

# realize <canon-path> -> R_REAL : resolve symlinks in the existing prefix.
# Spawns realpath only if some existing component is a symlink.
realize() {
  local p="$1" rest="" acc="" comp has_link=0 r=""
  local IFS='/'
  local -a parts
  read -ra parts <<<"$p"
  for comp in "${parts[@]}"; do
    [ -z "$comp" ] && continue
    if [ -n "$rest" ] || [ ! -e "$acc/$comp" ]; then
      rest="$rest/$comp"
    else
      acc="$acc/$comp"
      [ -L "$acc" ] && has_link=1
    fi
  done
  if [ "$has_link" = 1 ] && [ -n "$acc" ]; then
    if command -v realpath >/dev/null 2>&1; then r=$(realpath "$acc" 2>/dev/null)
    elif command -v readlink >/dev/null 2>&1; then r=$(readlink -f "$acc" 2>/dev/null)
    fi
    if [ -n "$r" ]; then norm "$r"; acc="$R_NORM"; fi
  fi
  R_REAL="${acc:-/}$rest"
}

# check_path <raw> <virtual-cwd> <label> -> R_PATH (canonical) or deny.
check_path() {
  local raw="$1" vcwd="$2" label="$3" p
  R_PATH="$vcwd"
  [ -z "$raw" ] && return 0
  case "$raw" in
    '~'|'~/'*|'~\'*) deny "$label '$raw' references the home directory" ;;
  esac
  norm "$raw"; p="$R_NORM"
  case "$p" in
    //*) deny "$label '$raw' is a UNC/network path" ;;
    /*) ;;
    *) p="$vcwd/$p" ;;
  esac
  canon "$p"; p="$R_CANON"
  inside "$p" || deny "$label '$raw' resolves to '$p', outside the repo"
  realize "$p"
  inside "$R_REAL" || deny "$label '$raw' resolves through a symlink to '$R_REAL', outside the repo"
  R_PATH="$p"
}

# --- cwd itself must be inside ---
if [ -n "$cwd" ]; then
  norm "$cwd"; canon "$R_NORM"; ncwd="$R_CANON"
  inside "$ncwd" || deny "session cwd '$cwd' is outside the repo"
else
  ncwd="$REPO_ROOT"
fi

# --- file tools ---
case "$tool" in
  Read|Edit|Write|MultiEdit|NotebookEdit|Glob|Grep)
    check_path "$fp" "$ncwd" "file_path"
    check_path "$nb" "$ncwd" "notebook_path"
    check_path "$gp" "$ncwd" "path"
    exit 0 ;;
  Bash|PowerShell) ;;
  *) exit 0 ;;
esac

# --- shell tools ---
[ -z "$cmd" ] && exit 0

# Variables and shorthands that point outside by construction.
tilde_re='(^|[^A-Za-z0-9_./=!-])~($|[/\"'"'"' ;&|)])'   # `=~` and `!~` are regex operators, not home
if [[ "$cmd" =~ $tilde_re ]]; then
  deny "command references '~' (home directory)"
fi
env_re='\$\{?(HOME|USERPROFILE|HOMEPATH|HOMEDRIVE|APPDATA|LOCALAPPDATA|PROGRAMDATA|PROGRAMFILES|SYSTEMROOT|WINDIR|TEMP|TMP|TMPDIR|OLDPWD|XDG_[A-Z_]+)([^A-Za-z0-9_]|$)|%[A-Za-z_]{2,}%|\$env:|\$\{env:|\[Environment\]::|\$PROFILE([^A-Za-z0-9_]|$)|\$PSScriptRoot'
if [[ "$cmd" =~ $env_re ]]; then
  deny "command references an environment variable that points outside the repo (HOME, USERPROFILE, TEMP, %VAR%, \$env:, ...)"
fi

# Split into simple segments (bash-only, no sed).
nl=$'\n'
segments="$cmd"
segments="${segments//&&/$nl}"; segments="${segments//||/$nl}"; segments="${segments//|&/$nl}"
segments="${segments//;/$nl}";  segments="${segments//|/$nl}"
segments="${segments//\$(/$nl}"; segments="${segments//\`/$nl}"
br='[(){}]'; segments="${segments//$br/$nl}"

vcwd="$ncwd"
while IFS= read -r seg; do
  seg="${seg//[$'\t\r']/ }"
  seg="${seg//\"/}"; seg="${seg//\'/}"
  set -f
  # shellcheck disable=SC2206
  toks=($seg)
  set +f
  [ ${#toks[@]} -eq 0 ] && continue
  # skip leading VAR=value assignments (values without paths) and known wrappers
  i=0
  while [ $i -lt ${#toks[@]} ] && [[ "${toks[$i]}" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^/\\]*$ ]]; do i=$((i+1)); done
  while [ $i -lt ${#toks[@]} ]; do
    case "${toks[$i]}" in
      sudo|env|command|builtin|exec|time|timeout|nice|nohup|xargs|eval|bash|sh|zsh|pwsh|powershell|-c|-e|-lc) i=$((i+1)); continue ;;
    esac
    break
  done
  [ $i -ge ${#toks[@]} ] && continue
  cmdword="${toks[$i]}"
  # cd-like commands move the virtual cwd
  case "${cmdword,,}" in
    cd|chdir|pushd|set-location|sl)
      target="${toks[$((i+1))]:-}"
      case "$target" in
        ''|-|--|-*) deny "'$cmdword $target' changes to an implicit directory (home/previous); use an explicit in-repo path" ;;
      esac
      check_path "$target" "$vcwd" "cd target"; vcwd="$R_PATH"
      continue ;;
    popd) vcwd="$ncwd"; continue ;;
  esac
  j=$i
  while [ $j -lt ${#toks[@]} ]; do
    t="${toks[$j]}"; j=$((j+1))
    # strip redirection prefixes and --opt=/KEY= prefixes
    t="${t#[0-9]}"; t="${t##[<>]}"; t="${t##[<>]}"; t="${t#&}"
    case "$t" in
      --*=*|-[A-Za-z]=*) t="${t#*=}" ;;
      [A-Za-z_]*=*) t="${t#*=}" ;;
    esac
    [ -z "$t" ] && continue
    case "$t" in
      *://*) continue ;;                              # URLs
      /dev/*|/proc/self/*) continue ;;                # pseudo files
      -*) [[ "$t" == *[/\\]* || "$t" == *..* ]] || continue ;;
    esac
    [[ "$t" =~ ^/[0-9.]+$ ]] && continue             # arithmetic like /1000000
    if [ "$t" = "/" ]; then                          # lone / is division when followed by a number or identifier
      nxt="${toks[$j]:-}"
      [[ "$nxt" =~ ^[A-Za-z0-9_.]+$ ]] && continue
    fi
    # path-like?
    if [[ "$t" == /* || "$t" == \\* || "$t" =~ ^[A-Za-z]:([/\\]|$) || "$t" == *[/\\]* || "$t" == '..' || "$t" == '.' ]]; then
      check_path "$t" "$vcwd" "path argument"
    fi
  done
done <<<"$segments"

exit 0
