#!/usr/bin/env bash
# _hook.sh — shared prologue for every plugin hook. Source after _root.sh:
#
#   . "${0%/*}/../scripts/_root.sh" || exit 2
#   . "$SDLC_PLUGIN_ROOT/scripts/_hook.sh"
#
# 1. Sources _project.sh, which exits 0 immediately (builtins only, no jq) when the
#    working directory is not an sdlc project. Plugin hooks fire in every session, in
#    every project: silence outside sdlc projects is the contract.
# 2. Reads the hook JSON once and exposes HOOK_TOOL, HOOK_CWD, HOOK_FILE (file_path or
#    notebook_path), HOOK_PATH (Glob/Grep path), HOOK_CMD, HOOK_AGENT, HOOK_EVENT.
#    Unparseable input denies (exit 2) unless HOOK_FAIL_OPEN=1 was set before sourcing.
# 3. Provides hook_deny, hook_rel, hook_cmd_paths, hook_list, hook_cmd_writes, hook_home
#    and hook_cmd_scan, the conservative shell-command classifier the write guards use.

. "$SDLC_PLUGIN_ROOT/scripts/_project.sh"
. "$SDLC_PLUGIN_ROOT/scripts/_lib.sh"
. "$SDLC_PLUGIN_ROOT/scripts/_glob.sh"

hook_deny() {  # hook_deny <message> : block the tool call with a reason Claude can act on
  echo "ai-sdlc guardrail: $1" >&2
  exit 2
}

IFS= read -r -d '' HOOK_INPUT || true
if ! HOOK__PARSED=$(jq -r '@sh "HOOK_TOOL=\(.tool_name // "") HOOK_CWD=\(.cwd // "") HOOK_FILE=\(.tool_input.file_path // .tool_input.notebook_path // "") HOOK_PATH=\(.tool_input.path // "") HOOK_CMD=\(.tool_input.command // "") HOOK_AGENT=\(.agent_type // "") HOOK_EVENT=\(.hook_event_name // "")"' <<<"$HOOK_INPUT" 2>/dev/null) || [ -z "$HOOK__PARSED" ]; then
  if [ "${HOOK_FAIL_OPEN:-0}" = 1 ]; then exit 0; fi
  hook_deny "${0##*/} received input that is not valid hook JSON; refusing to guess"
fi
eval "$HOOK__PARSED"
unset HOOK__PARSED

HOOK_PROJECT=$(sdlc_norm_path "$SDLC_PROJECT_DIR")
# shellcheck disable=SC2034 # Sourced hook scripts consume this shared artifact directory.
HOOK_ARTIFACTS=$(sdlc_artifacts_dir)
hook_home() { sdlc_norm_path "${HOME:-${USERPROFILE:-}}"; }

# hook_rel <path> : project-relative with forward slashes (absolute if outside the project)
hook_rel() {
  local p; p=$(sdlc_norm_path "$1")
  case "$p" in /*) ;; *) p="$(sdlc_norm_path "${HOOK_CWD:-$PWD}")/$p" ;; esac
  p=$(sdlc_abs_path "$p")
  case "${p,,}" in "${HOOK_PROJECT,,}"/*) printf '%s' "${p:$(( ${#HOOK_PROJECT} + 1 ))}" ;; *) printf '%s' "$p" ;; esac
}

# hook_list <jq path> [default...] : config array as lines, defaults when absent
hook_list() {
  local q="$1"; shift
  local v; v=$(jq -r "$q // empty | .[]?" "$SDLC_CONFIG" 2>/dev/null)
  if [ -n "$v" ]; then printf '%s\n' "$v"; else printf '%s\n' "$@"; fi
}

# hook_cmd_paths <command> : path-like tokens of a shell command, one per line
hook_cmd_paths() {
  local cmd="$1" nl=$'\n' seg t br='[(){}]'
  cmd="${cmd//&&/$nl}"; cmd="${cmd//||/$nl}"; cmd="${cmd//;/$nl}"; cmd="${cmd//|/$nl}"; cmd="${cmd//\$(/$nl}"; cmd="${cmd//\`/$nl}"; cmd="${cmd//$br/$nl}"
  while IFS= read -r seg; do
    seg="${seg//\"/}"; seg="${seg//\'/}"
    local -a toks=()
    read -r -a toks <<<"$seg"
    for t in "${toks[@]+"${toks[@]}"}"; do
      t="${t#[0-9]}"; t="${t##[<>]}"; t="${t##[<>]}"; t="${t#&}"
      case "$t" in --*=*|-[A-Za-z]=*|[A-Za-z_]*=*) t="${t#*=}" ;; esac
      [ -z "$t" ] && continue
      case "$t" in *://*|/dev/*|-*) continue ;; esac
      # every remaining token may name a file (a bare `CODEOWNERS` or `.env` included);
      # command words like `rm` simply match no glob
      t="${t/#\$HOME/$(hook_home)}"; t="${t/#\$USERPROFILE/$(hook_home)}"; t="${t/#\~/$(hook_home)}"
      printf '%s\n' "$t"
    done
  done <<<"$cmd"
}

# hook_cmd_writes <command> : exit 0 when the command can modify files (broad regex; the
# protected-paths guard combines it with hook_cmd_paths). The gates use hook_cmd_scan.
hook_cmd_writes() {
  local c="$1"
  local re='(^|[[:space:];&|(`]|[[:space:]])(rm|mv|cp|tee|touch|truncate|install|ln|mkdir|rmdir|dd|chmod|chown|shred|patch|sed[[:space:]]+(-[a-zA-Z]*i|--in-place)|perl[[:space:]]+-[a-zA-Z]*i|python[3]?[[:space:]]+-c|git[[:space:]]+(add|commit|push|checkout|switch|restore|reset|stash|rebase|merge|cherry-pick|rm|mv|clean|apply|am|tag|branch[[:space:]]+-[dDm]|worktree|filter-branch|update-ref)|npm[[:space:]]+(i|install|ci|update|uninstall|link|publish)|pnpm[[:space:]]+(add|install|remove)|yarn[[:space:]]+(add|remove)|pip[3]?[[:space:]]+(install|uninstall)|Set-Content|Add-Content|Out-File|Remove-Item|Move-Item|Copy-Item|New-Item|Rename-Item|Clear-Content)([[:space:]]|$)'
  [[ "$c" =~ $re ]] && return 0
  # redirections other than to /dev/null or fd duplication
  local stripped="${c//2>&1/}"; stripped="${stripped//>\/dev\/null/}"; stripped="${stripped//> \/dev\/null/}"; stripped="${stripped//&>\/dev\/null/}"
  [[ "$stripped" =~ (^|[^\>\<])\>[^\>]|\>\> ]] && return 0
  return 1
}

# ---------------------------------------------------------------------------------------
# hook_cmd_scan <command> : conservative classifier for Bash and PowerShell commands.
#
# Robust target-level analysis of a shell command is not possible (variables, scripts,
# interpreters, downloads), so the scan is deliberately pessimistic: it recognises an
# explicit set of read-only commands and an explicit set of write commands whose file
# targets are visible in the command text; everything else is "opaque". Results:
#
#   HOOK_SCAN_CLASS    readonly | verify | gitmeta | plugin | writes | opaque (worst segment)
#   HOOK_SCAN_TARGETS  newline list of concrete write targets (absolute or cwd-relative)
#   HOOK_SCAN_DYNAMIC  1 when a write target, a cd target or a redirection cannot be
#                      resolved statically ($var, glob, backtick, home shorthand, %VAR%)
#   HOOK_SCAN_OPAQUE   newline list of the opaque segments (for the deny message)
#   HOOK_SCAN_PLUGIN   newline list of plugin operations seen ("script:<subpath>" or
#                      "platform:<function>")
#   HOOK_SCAN_VERIFY   newline list of segments that matched commands.verify/lint/format or a
#                      known test runner ("runner:<segment>")
#   HOOK_SCAN_GITMETA  newline list of git segments that change refs or the index but not the
#                      working tree (commit, push, fetch, branch -d, tag, ...)
#
# Class order (worst wins): readonly < verify < gitmeta < plugin < writes < opaque.
# ---------------------------------------------------------------------------------------
hook__scan_rank() { case "$1" in readonly) echo 0 ;; verify) echo 1 ;; gitmeta) echo 2 ;; plugin) echo 3 ;; writes) echo 4 ;; *) echo 5 ;; esac; }
hook__scan_worse() {  # hook__scan_worse <class> : raise HOOK_SCAN_CLASS when <class> is worse
  [ "$(hook__scan_rank "$1")" -gt "$(hook__scan_rank "$HOOK_SCAN_CLASS")" ] && HOOK_SCAN_CLASS="$1"
  return 0
}
hook__scan_dynamic_tok() {  # exit 0 when a token cannot be resolved statically
  case "$1" in *'$'*|*'`'*|*'*'*|*'?'*|*'['*|*'{'*|'~'*|*'%'*) return 0 ;; esac
  return 1
}
hook__scan_add_target() {  # hook__scan_add_target <token> <vcwd>
  local t="$1" v="$2"
  [ -z "$t" ] && return 0
  if hook__scan_dynamic_tok "$t" || [ "$HOOK__SCAN_VCWD_DYNAMIC" = 1 ]; then HOOK_SCAN_DYNAMIC=1; return 0; fi
  t=$(sdlc_norm_path "$t")
  case "$t" in /*) ;; *) t="$v/$t" ;; esac
  HOOK_SCAN_TARGETS="${HOOK_SCAN_TARGETS}${t}"$'\n'
}
hook__scan_norm() {  # normalise whitespace of a segment for comparison with configured commands
  local s="$1" out="" t
  local -a toks=()
  read -r -a toks <<<"$s"
  for t in "${toks[@]+"${toks[@]}"}"; do out="${out:+$out }$t"; done
  printf '%s' "$out"
}
hook__scan_after() {  # hook__scan_after <flag> <args...> : the value after <flag>
  local k="$1"; shift
  while [ $# -gt 0 ]; do if [ "${1,,}" = "${k,,}" ]; then printf '%s' "${2:-}"; return; fi; shift; done
}
hook__scan_gitmeta() {  # hook__scan_gitmeta <segment> : git metadata mutation (no working-tree change)
  hook__scan_worse gitmeta; HOOK_SCAN_GITMETA="${HOOK_SCAN_GITMETA}$1"$'\n'
}

hook_cmd_scan() {
  local cmd="$1" nl=$'\n' seg br='[(){}]'
  HOOK_SCAN_CLASS="readonly"; HOOK_SCAN_TARGETS=""; HOOK_SCAN_DYNAMIC=0; HOOK_SCAN_OPAQUE=""; HOOK_SCAN_PLUGIN=""; HOOK_SCAN_VERIFY=""
  HOOK_SCAN_GITMETA=""
  HOOK__SCAN_VCWD_DYNAMIC=0
  local vcwd; vcwd=$(sdlc_norm_path "${HOOK_CWD:-$PWD}")
  local cfg_verify cfg_lint cfg_format root_norm
  cfg_verify=$(hook__scan_norm "$(sdlc_config '.commands.verify' '')")
  cfg_lint=$(hook__scan_norm "$(sdlc_config '.commands.lint' '')")
  cfg_format=$(hook__scan_norm "$(sdlc_config '.commands.format' '')")
  root_norm=$(sdlc_norm_path "$SDLC_PLUGIN_ROOT")

  # ${NAME} -> $NAME so that brace splitting below does not cut variable references apart
  while [[ "$cmd" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do cmd="${cmd//"${BASH_REMATCH[0]}"/\$${BASH_REMATCH[1]}}"; done
  cmd="${cmd//&&/$nl}"; cmd="${cmd//||/$nl}"; cmd="${cmd//|&/$nl}"; cmd="${cmd//;/$nl}"; cmd="${cmd//|/$nl}"
  cmd="${cmd//\$(/$nl}"; cmd="${cmd//\`/$nl}"; cmd="${cmd//$br/$nl}"
  while IFS= read -r seg; do
    seg="${seg//[$'\t\r']/ }"
    # a segment that is a quoted literal ("text" | Set-Content f) is data, not a command
    local trimmed="${seg#"${seg%%[! ]*}"}"
    case "$trimmed" in \"*|\'*) continue ;; esac
    seg="${seg//\"/}"; seg="${seg//\'/}"
    local -a toks=()
    read -r -a toks <<<"$seg"
    [ ${#toks[@]} -eq 0 ] && continue
    local n=${#toks[@]} i=0 t j cls=readonly word lw tgt
    local -a args=()
    # redirections anywhere in the segment are write targets (except /dev/null and fd dups)
    j=0
    while [ $j -lt $n ]; do
      t="${toks[$j]}"
      case "$t" in
        [0-9]\>\&[0-9]|\>\&[0-9]|[0-9]\>\&-|\>\&-|\<*|[0-9]\<*) ;;
        \>\>|\>|\&\>|[0-9]\>|\>\||\&\>\>|[0-9]\>\>)
          tgt="${toks[$((j+1))]:-}"
          case "$tgt" in /dev/null|/dev/stdout|/dev/stderr|'') ;; *) cls=writes; hook__scan_add_target "$tgt" "$vcwd" ;; esac ;;
        \>\>*|\>*|\&\>*|[0-9]\>*)
          tgt="${t#[0-9]}"; tgt="${tgt#&}"; tgt="${tgt##\>}"; tgt="${tgt##\>}"; tgt="${tgt#|}"
          case "$tgt" in /dev/null|/dev/stdout|/dev/stderr|'') ;; *) cls=writes; hook__scan_add_target "$tgt" "$vcwd" ;; esac ;;
      esac
      j=$((j+1))
    done
    # leading VAR=value assignments and wrappers
    while [ $i -lt $n ] && [[ "${toks[$i]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do i=$((i+1)); done
    [ $i -ge $n ] && continue
    # configured project commands: verify exact, lint/format as prefix (format writes its args)
    local nseg; nseg=$(hook__scan_norm "${toks[*]:$i}")
    if [ -n "$cfg_verify" ] && [ "$nseg" = "$cfg_verify" ]; then
      HOOK_SCAN_VERIFY="${HOOK_SCAN_VERIFY}verify"$'\n'; hook__scan_worse verify; [ "$cls" = writes ] && hook__scan_worse writes; continue
    fi
    if [ -n "$cfg_lint" ] && { [ "$nseg" = "$cfg_lint" ] || [ "${nseg#"$cfg_lint" }" != "$nseg" ]; }; then
      HOOK_SCAN_VERIFY="${HOOK_SCAN_VERIFY}lint"$'\n'; hook__scan_worse verify; [ "$cls" = writes ] && hook__scan_worse writes; continue
    fi
    if [ -n "$cfg_format" ] && { [ "$nseg" = "$cfg_format" ] || [ "${nseg#"$cfg_format" }" != "$nseg" ]; }; then
      HOOK_SCAN_VERIFY="${HOOK_SCAN_VERIFY}format"$'\n'; hook__scan_worse writes
      local rest="${nseg#"$cfg_format"}"
      local -a ftoks=()
      read -r -a ftoks <<<"$rest"
      for t in "${ftoks[@]+"${ftoks[@]}"}"; do case "$t" in -*) ;; *) hook__scan_add_target "$t" "$vcwd" ;; esac; done
      continue
    fi
    while [ $i -lt $n ]; do
      case "${toks[$i]}" in
        sudo|env|command|builtin|exec|time|nice|nohup|-c|-e|-lc|-Command|-command|-NoProfile|-noprofile|-ExecutionPolicy|-executionpolicy|Bypass|bypass) i=$((i+1)); continue ;;
        timeout) i=$((i+2)); continue ;;
        bash|sh|zsh|dash|pwsh|powershell|powershell.exe|pwsh.exe)
          local nxt="${toks[$((i+1))]:-}"
          case "$nxt" in
            -c|-lc|-Command|-command|-NoProfile|-noprofile|-ExecutionPolicy|-executionpolicy) i=$((i+1)); continue ;;
            '') i=$((i+1)); continue ;;
          esac
          # `bash <script>`: a plugin script is a documented operation, anything else is opaque
          local scr="$nxt" subp=""
          scr="${scr//\\//}"
          case "$scr" in
            '$CLAUDE_PLUGIN_ROOT/'*) subp="${scr#\$CLAUDE_PLUGIN_ROOT/}" ;;
            '$SDLC_PLUGIN_ROOT/'*) subp="${scr#\$SDLC_PLUGIN_ROOT/}" ;;
            *) local scrn; scrn=$(sdlc_norm_path "$scr"); case "${scrn,,}" in "${root_norm,,}"/*) subp="${scrn:$(( ${#root_norm} + 1 ))}" ;; esac ;;
          esac
          if [ -n "$subp" ]; then
            HOOK_SCAN_PLUGIN="${HOOK_SCAN_PLUGIN}script:${subp}"$'\n'; hook__scan_worse plugin; cls=""
          else
            cls=opaque
          fi
          i=$n; break ;;
      esac
      break
    done
    [ -z "$cls" ] && continue                    # plugin script segment, already classified
    if [ $i -ge $n ]; then
      case "$cls" in
        writes) hook__scan_worse writes ;;
        opaque) hook__scan_worse opaque; HOOK_SCAN_OPAQUE="${HOOK_SCAN_OPAQUE}${toks[*]}"$'\n' ;;
      esac
      continue
    fi
    word="${toks[$i]}"; lw="${word,,}"
    args=("${toks[@]:$((i+1))}")

    # positional (non-option) arguments
    local -a pos=()
    for t in "${args[@]+"${args[@]}"}"; do
      case "$t" in
        \>\&*|\&\>*|[0-9]\>\&*|[0-9]\>*|\<*|[0-9]\<*|\>*) ;;       # redirections handled above
        -*) ;;
        *) pos+=("$t") ;;
      esac
    done
    local npos=${#pos[@]}

    case "$lw" in
      # --- shell state and no-ops
      cd|chdir|pushd|set-location|sl)
        local target="${pos[0]:-}"
        case "$target" in
          ''|-|--|'~'*) HOOK__SCAN_VCWD_DYNAMIC=1 ;;
          *) if hook__scan_dynamic_tok "$target"; then HOOK__SCAN_VCWD_DYNAMIC=1
             else target=$(sdlc_norm_path "$target"); case "$target" in /*) ;; *) target="$vcwd/$target" ;; esac; vcwd=$(sdlc_abs_path "$target"); fi ;;
        esac ;;
      popd) vcwd=$(sdlc_norm_path "${HOOK_CWD:-$PWD}") ;;
      export|set|unset|shopt|ulimit|umask|alias|unalias|declare|local|typeset|readonly|let|:|true|false|exit|return|wait|trap|read|hash|echo|printf|write-output|write-host|write-verbose|write-warning|write-error|write-information) ;;
      # --- read-only Unix commands
      cat|less|more|head|tail|wc|grep|egrep|fgrep|zgrep|rg|ag|ack|ls|ll|tree|stat|file|du|df|diff|cmp|comm|sort|uniq|cut|tr|column|paste|nl|od|xxd|hexdump|strings|pwd|date|printenv|which|type|whoami|id|uname|hostname|test|\[|\[\[|sleep|basename|dirname|realpath|readlink|jq|yq|md5sum|sha1sum|sha256sum|shasum|cksum|tac|rev|seq|expr|bc|ps|uptime|free|locate|getconf|nproc|ldd|shellcheck|mypy|flake8|pylint|hadolint|yamllint|markdownlint|actionlint) ;;
      awk|gawk|mawk|nawk) case " ${args[*]:-} " in *'>'*) cls=opaque ;; esac ;;
      sed)
        local inplace=0 have_e=0
        for t in "${args[@]+"${args[@]}"}"; do case "$t" in -i*|--in-place*|-[a-zA-Z]*i*) inplace=1 ;; -e|--expression|-f|--file|-e*) have_e=1 ;; esac; done
        if [ $inplace = 1 ]; then
          cls=writes
          local k=0; for t in "${pos[@]+"${pos[@]}"}"; do if [ $have_e = 0 ] && [ $k = 0 ]; then k=1; continue; fi; hook__scan_add_target "$t" "$vcwd"; k=$((k+1)); done
          [ ${#pos[@]} -le 1 ] && [ $have_e = 0 ] && HOOK_SCAN_DYNAMIC=1
        fi ;;
      find)
        case " ${args[*]:-} " in *' -delete '*|*' -exec '*|*' -execdir '*|*' -ok '*|*' -okdir '*|*' -fprint'*) cls=opaque ;; esac ;;
      curl) case " ${args[*]:-} " in *' -o '*|*' -O '*|*' --output '*|*' -o'*|*' --remote-name '*) cls=opaque ;; esac ;;
      # --- read-only PowerShell cmdlets and aliases
      get-content|gc|get-childitem|gci|dir|get-item|gi|get-location|gl|select-string|sls|select-object|select|where-object|where|\?|foreach-object|foreach|%|format-table|ft|format-list|fl|out-string|measure-object|measure|sort-object|get-date|test-path|resolve-path|rvpa|get-command|gcm|get-process|gps|compare-object|compare|convertfrom-json|convertto-json|get-filehash|split-path|join-path|get-help|out-host|oh|get-member|gm) ;;
      # --- test runners and linters (verify class: no source change, but not read-only either)
      pytest|py.test|vitest|jest|mocha|ava|tap|dotnet|mvn|gradle|./gradlew|gradlew|go|cargo|make|npm|pnpm|yarn|bun|npx|eslint|prettier|tsc|ruff|black|gofmt|rustfmt|shfmt|rubocop|bundle)
        local ok=0 a1="${args[0]:-}" a2="${args[1]:-}"
        case "$lw" in
          pytest|py.test|vitest|jest|mocha|ava|tap) ok=1 ;;
          dotnet) case "$a1" in test) ok=1 ;; format) case " ${args[*]} " in *' --verify-no-changes '*|*' --check '*) ok=1 ;; esac ;; esac ;;
          mvn) case "$a1" in test|verify|-q) ok=1 ;; esac ;;
          gradle|./gradlew|gradlew) case "$a1" in test|check) ok=1 ;; esac ;;
          go) case "$a1" in test|vet|version|env|list) ok=1 ;; esac ;;
          cargo) case "$a1" in test|check|clippy|--version) ok=1 ;; fmt) case " ${args[*]} " in *' --check '*) ok=1 ;; esac ;; esac ;;
          make) case "$a1" in test|check|verify|lint) ok=1 ;; esac ;;
          npm) case "$a1" in test|t|tst) ok=1 ;; run|run-script) case "$a2" in test|test:*|verify|lint|check|typecheck|tsc) ok=1 ;; esac ;; --version|-v|ls|ll|la|view|outdated|audit) ok=1 ;; esac ;;
          pnpm|yarn|bun) case "$a1" in test|t|verify|lint|check|typecheck|--version|-v|why|outdated|audit|list|ls) ok=1 ;; run) case "$a2" in test|test:*|verify|lint|check|typecheck|tsc) ok=1 ;; esac ;; esac ;;
          npx) case "$a1" in vitest|jest|mocha|ava|tsc|eslint|prettier|shellcheck|ruff|black|mypy|flake8|pylint) ok=1 ;; esac
               case " ${args[*]} " in *' --fix '*|*' --write '*|*' -w '*) ok=0 ;; esac
               [ "$a1" = tsc ] && { case " ${args[*]} " in *' --noEmit '*) ;; *) ok=0 ;; esac; }
               [ "$a1" = prettier ] && { case " ${args[*]} " in *' --check '*|*' -c '*|*' -l '*|*' --list-different '*) ;; *) ok=0 ;; esac; } ;;
          eslint) ok=1; case " ${args[*]} " in *' --fix '*|*' --fix-dry-run '*) ok=0 ;; esac ;;
          prettier) case " ${args[*]} " in *' --check '*|*' -c '*|*' -l '*|*' --list-different '*) ok=1 ;; esac ;;
          tsc) case " ${args[*]} " in *' --noEmit '*) ok=1 ;; esac ;;
          ruff) case "$a1" in check) ok=1 ;; format) case " ${args[*]} " in *' --check '*|*' --diff '*) ok=1 ;; esac ;; esac; case " ${args[*]} " in *' --fix '*) ok=0 ;; esac ;;
          black|rustfmt|shfmt) case " ${args[*]} " in *' --check '*|*' --diff '*|*' -l '*|*' -d '*) ok=1 ;; esac ;;
          gofmt) case " ${args[*]} " in *' -w '*) ok=0 ;; *) ok=1 ;; esac ;;
          rubocop) ok=1; case " ${args[*]} " in *' -a '*|*' -A '*|*' --auto-correct'*|*' --autocorrect'*) ok=0 ;; esac ;;
          bundle) case "$a1 $a2" in "exec rspec"|"exec rubocop") ok=1 ;; esac ;;
        esac
        if [ $ok = 1 ]; then hook__scan_worse verify; HOOK_SCAN_VERIFY="${HOOK_SCAN_VERIFY}runner:${toks[*]:$i}"$'\n'; else cls=opaque; fi ;;
      # --- write commands with visible targets
      rm|rmdir|unlink|touch|mkdir|truncate|shred|chmod|chown|chgrp|mkfifo|tee)
        cls=writes; for t in "${pos[@]+"${pos[@]}"}"; do hook__scan_add_target "$t" "$vcwd"; done
        [ $npos -eq 0 ] && [ "$lw" != tee ] && HOOK_SCAN_DYNAMIC=1 ;;
      mv|move|move-item|mi|rename-item|rni|ren)
        cls=writes; for t in "${pos[@]+"${pos[@]}"}"; do hook__scan_add_target "$t" "$vcwd"; done
        for t in "${args[@]+"${args[@]}"}"; do case "${t,,}" in -path|-literalpath|-destination|-newname) hook__scan_add_target "$(hook__scan_after "$t" "${args[@]}")" "$vcwd" ;; esac; done
        [ $npos -eq 0 ] && HOOK_SCAN_DYNAMIC=1 ;;
      cp|copy|copy-item|cpi|install|ln|rsync)
        cls=writes
        local dest=""
        for t in "${args[@]+"${args[@]}"}"; do case "${t,,}" in -t|--target-directory|-destination) dest=$(hook__scan_after "$t" "${args[@]}") ;; esac; done
        [ -z "$dest" ] && [ $npos -gt 0 ] && dest="${pos[$((npos-1))]}"
        if [ -n "$dest" ]; then hook__scan_add_target "$dest" "$vcwd"; else HOOK_SCAN_DYNAMIC=1; fi ;;
      dd)
        cls=writes; local of=""
        for t in "${args[@]+"${args[@]}"}"; do case "$t" in of=*) of="${t#of=}" ;; esac; done
        if [ -n "$of" ]; then hook__scan_add_target "$of" "$vcwd"; else HOOK_SCAN_DYNAMIC=1; fi ;;
      patch)
        cls=writes; if [ $npos -gt 0 ]; then hook__scan_add_target "${pos[0]}" "$vcwd"; else HOOK_SCAN_DYNAMIC=1; fi ;;
      set-content|sc|add-content|ac|out-file|new-item|ni|remove-item|ri|del|erase|rd|clear-content|clc|set-itemproperty|sp|export-csv|epcsv|export-clixml|set-item|si)
        cls=writes; local named=0
        for t in "${args[@]+"${args[@]}"}"; do case "${t,,}" in -path|-literalpath|-filepath|-destination) named=1; hook__scan_add_target "$(hook__scan_after "$t" "${args[@]}")" "$vcwd" ;; esac; done
        if [ $named = 0 ]; then
          if [ $npos -gt 0 ]; then hook__scan_add_target "${pos[0]}" "$vcwd"; else HOOK_SCAN_DYNAMIC=1; fi
        fi ;;
      # --- git
      git)
        local k=0 a="" gsub=""
        while [ $k -lt ${#args[@]} ]; do
          a="${args[$k]}"
          case "$a" in -C|--git-dir|--work-tree|-c) k=$((k+2)); continue ;; -*) k=$((k+1)); continue ;; esac
          gsub="$a"; break
        done
        local -a gargs=("${args[@]:$((k+1))}") gpos=()
        for t in "${gargs[@]+"${gargs[@]}"}"; do case "$t" in -*) ;; *) gpos+=("$t") ;; esac; done
        case "$gsub" in
          ''|status|log|diff|show|rev-parse|describe|blame|ls-files|ls-tree|cat-file|grep|shortlog|reflog|name-rev|merge-base|rev-list|for-each-ref|version|help|var|check-ignore|check-attr|count-objects|fsck|verify-pack|whatchanged|range-diff|cherry|diff-tree|diff-index|diff-files|show-ref|symbolic-ref|show-branch|--version|--help) ;;
          branch|tag|remote|config|stash|worktree|submodule|notes|bisect)
            local mutating=0
            case "$gsub" in
              branch) [ ${#gpos[@]} -gt 0 ] && mutating=1; case " ${gargs[*]:-} " in *' -d '*|*' -D '*|*' -m '*|*' -M '*|*' --delete '*|*' --move '*|*' -u '*|*' --set-upstream-to'*) mutating=1 ;; esac ;;
              tag) [ ${#gpos[@]} -gt 0 ] && mutating=1; case " ${gargs[*]:-} " in *' -l '*|*' --list '*) mutating=0 ;; *' -d '*|*' -a '*|*' -f '*) mutating=1 ;; esac ;;
              remote) case "${gpos[0]:-}" in ''|show|get-url) ;; *) mutating=1 ;; esac ;;
              config) case " ${gargs[*]:-} " in *' --get '*|*' --get-all '*|*' --get-regexp '*|*' --list '*|*' -l '*) ;; *) [ ${#gpos[@]} -gt 0 ] && mutating=1 ;; esac ;;
              stash) case "${gpos[0]:-}" in list|show) ;; *) mutating=1; HOOK_SCAN_DYNAMIC=1 ;; esac ;;
              worktree) case "${gpos[0]:-}" in list) ;; *) mutating=1; HOOK_SCAN_DYNAMIC=1 ;; esac ;;
              submodule) case "${gpos[0]:-}" in status|summary|'') ;; *) mutating=1; HOOK_SCAN_DYNAMIC=1 ;; esac ;;
              notes|bisect) mutating=1 ;;
            esac
            if [ $mutating = 1 ]; then
              if [ "$HOOK_SCAN_DYNAMIC" = 1 ]; then cls=writes; else hook__scan_gitmeta "${toks[*]:$i}"; fi
            fi ;;
          commit|push|fetch|init|gc|prune|update-index|write-tree|commit-tree|update-server-info|maintenance)
            hook__scan_gitmeta "${toks[*]:$i}" ;;
          checkout|switch)
            case " ${gargs[*]:-} " in
              *' -b '*|*' -c '*|*' --orphan '*) hook__scan_gitmeta "${toks[*]:$i}" ;;
              *) cls=writes; HOOK_SCAN_DYNAMIC=1 ;;                 # may restore paths
            esac ;;
          add)
            cls=writes
            case " ${gargs[*]:-} " in *' -A '*|*' --all '*|*' -u '*|*' --update '*|*' -a '*|*' -p '*|*' -i '*) HOOK_SCAN_DYNAMIC=1 ;; esac
            [ ${#gpos[@]} -eq 0 ] && HOOK_SCAN_DYNAMIC=1
            for t in "${gpos[@]+"${gpos[@]}"}"; do case "$t" in .|./|..) HOOK_SCAN_DYNAMIC=1 ;; *) hook__scan_add_target "$t" "$vcwd" ;; esac; done ;;
          rm|mv)
            cls=writes; [ ${#gpos[@]} -eq 0 ] && HOOK_SCAN_DYNAMIC=1
            for t in "${gpos[@]+"${gpos[@]}"}"; do hook__scan_add_target "$t" "$vcwd"; done ;;
          *) cls=writes; HOOK_SCAN_DYNAMIC=1 ;;                          # pull merge rebase reset restore revert cherry-pick am apply clean ...
        esac ;;
      # --- the plugin's own dispatcher is a documented operation
      sdlc-platform)
        local fn=""
        for t in "${pos[@]+"${pos[@]}"}"; do case "$t" in github|azure|none|both|auto) ;; *) fn="$t"; break ;; esac; done
        HOOK_SCAN_PLUGIN="${HOOK_SCAN_PLUGIN}platform:${fn:-?}"$'\n'; hook__scan_worse plugin ;;
      # --- everything else: interpreters, scripts, package managers, downloads, archives, unknown
      *) cls=opaque ;;
    esac
    case "$cls" in
      opaque) hook__scan_worse opaque; HOOK_SCAN_OPAQUE="${HOOK_SCAN_OPAQUE}${toks[*]:$i}"$'\n' ;;
      writes) hook__scan_worse writes ;;
    esac
  done <<<"$cmd"
  return 0
}

# hook_scan_targets_rel : HOOK_SCAN_TARGETS as project-relative paths, one per line
hook_scan_targets_rel() {
  local t
  while IFS= read -r t; do [ -n "$t" ] || continue; hook_rel "$t"; echo; done <<<"$HOOK_SCAN_TARGETS"
}
