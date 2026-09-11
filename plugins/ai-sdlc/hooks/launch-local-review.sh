#!/usr/bin/env bash
# launch-local-review.sh (PostToolUse: Bash|PowerShell)
# review.runner local: after a command created a pull request (or synchronised an unreviewed
# commit of a branch that has one), open a NEW terminal window running a fresh Claude Code
# session with `/ai-sdlc:sdlc-review --launch <id> --pr <n>`. The reviewer is never the author
# session: it uses the developer's own Claude login (session-state variables of this session are
# stripped; with review.localAuth login the API-key and provider variables too), reviews the PR
# head in an isolated worktree and posts the report. This hook never denies (exit 0 always); a
# launch it cannot perform is reported in the note it returns to the author session.
#
# Supported command subset (anything else never launches; the manual command is documented):
#   sdlc-platform [--platform github|azure] pr_create ...   id from the adapter's stdout {"id":"n"}
#   gh pr create ...                                        id from the /pull/<n> URL on stdout;
#                                                           -R|--repo must be repo.owner/repo.name
#   az repos pr create ...                                  id from "pullRequestId": n on stdout;
#                                                           --repository/--project/--org must match
#   git push ...                                            not proof of execution: the hook checks
#                                                           for an UNREVIEWED SYNCHRONISED COMMIT
#                                                           (current branch mapped to a PR, its
#                                                           remote-tracking ref equals HEAD, and no
#                                                           launch exists for that sha yet)
# Segments are split on && || ; | and newlines outside quotes; a segment holding $( or a backtick
# before the command word, or starting with eval, is ignored; leading NAME=value assignments are
# skipped; --dry-run/--mock segments and SDLC_DRY_RUN=1/SDLC_PLATFORM_MOCK=1 commands never
# launch; a creation without an id on stdout means nothing was created. A failed tool call is a
# PostToolUseFailure event and never reaches this hook.
#
# Environment knobs (evals): SDLC_LAUNCH_DRY_RUN=1 writes the launcher and prints the launch
# command on stderr without running it; SDLC_REVIEW_TERMINAL=wt|cmd|open|osascript|
# x-terminal-emulator|gnome-terminal|konsole|xterm|none overrides terminal detection;
# SDLC_CLAUDE_BIN names the claude executable.
set -u
. "${0%/*}/../scripts/_root.sh" || exit 0
# shellcheck disable=SC2034 # _hook.sh reads it when the input does not parse
HOOK_FAIL_OPEN=1
. "$SDLC_PLUGIN_ROOT/scripts/_hook.sh"
[ "$HOOK_EVENT" = PostToolUse ] || exit 0
case "$HOOK_TOOL" in Bash|PowerShell) ;; *) exit 0 ;; esac
[ -n "$HOOK_CMD" ] || exit 0
[ ${#HOOK_CMD} -le 20000 ] || exit 0
# cheap pre-filter before any further process is spawned
[[ "$HOOK_CMD" =~ pr_create|pr[[:space:]]+create|git[[:space:]]+push ]] || exit 0
case "$HOOK_CMD" in *SDLC_DRY_RUN=1*|*SDLC_PLATFORM_MOCK=1*) exit 0 ;; esac

STATUS="$SDLC_PLUGIN_ROOT/scripts/review/status.sh"
eval "$(jq -r '@sh "runner=\(.review.runner // "ci") launcher_tpl=\(.review.localLauncher // "") auth=\(.review.localAuth // "login") platform=\(.platform // "none") owner=\(.repo.owner // "") name=\(.repo.name // "") az_repo=\(.azure.repo // "") az_project=\(.azure.project // "") az_org=\(.azure.organization // "") default_branch=\(.repo.defaultBranch // "main")"' "$SDLC_CONFIG" 2>/dev/null)" || exit 0
[ "${runner:-ci}" = local ] || exit 0
[ "${platform:-none}" != none ] || exit 0

note() { echo "ai-sdlc: $*" >&2; }

# --- 1. split the command into segments outside quotes -------------------------------------
segments=()
split_segments() {
  local cmd="$1" i c q="" seg="" n=${#1} nxt
  for (( i=0; i<n; i++ )); do
    c="${cmd:$i:1}"; nxt="${cmd:$((i+1)):1}"
    if [ -n "$q" ]; then
      seg="$seg$c"; [ "$c" = "$q" ] && q=""
      continue
    fi
    case "$c" in
      "'"|'"') q="$c"; seg="$seg$c" ;;
      $'\n'|';') segments+=("$seg"); seg="" ;;
      '&') if [ "$nxt" = '&' ]; then segments+=("$seg"); seg=""; i=$((i+1)); else seg="$seg$c"; fi ;;
      '|') segments+=("$seg"); seg=""; [ "$nxt" = '|' ] && i=$((i+1)) ;;
      *) seg="$seg$c" ;;
    esac
  done
  segments+=("$seg")
}
split_segments "$HOOK_CMD"

# --- 2. find the first supported creating or pushing segment ------------------------------
kind=""; match_seg=""
re_env='^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+'
re_sp='^([^[:space:]]*/)?sdlc-platform([[:space:]]+--platform[[:space:]]+(github|azure))?[[:space:]]+pr_create([[:space:]]|$)'
re_gh='^gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'
re_az='^az[[:space:]]+repos[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'
re_push='^git[[:space:]]+push([[:space:]]|$)'
for seg in "${segments[@]}"; do
  seg="${seg#"${seg%%[![:space:]]*}"}"
  while [[ "$seg" =~ $re_env ]]; do seg="${seg#"${BASH_REMATCH[0]}"}"; done
  [ -n "$seg" ] || continue
  case "$seg" in eval\ *|*'$('*|*'`'*) continue ;; esac
  if [[ "$seg" =~ $re_sp ]]; then kind=adapter
  elif [[ "$seg" =~ $re_gh ]]; then kind=gh
  elif [[ "$seg" =~ $re_az ]]; then kind=az
  elif [[ "$seg" =~ $re_push ]]; then kind=push
  else continue; fi
  match_seg="$seg"; break
done
[ -n "$kind" ] || exit 0
[[ "$match_seg" =~ (^|[[:space:]])--(dry-run|mock)([[:space:]]|=|$) ]] && exit 0

# --- 3. the pull request id, or the unreviewed synchronised commit ---------------------------
pr=""; trigger=pr_create
stdout=$(jq -r 'if (.tool_response|type)=="string" then .tool_response elif (.tool_response|type)=="object" then (.tool_response.stdout // (.tool_response.output // "")) else "" end' <<<"$HOOK_INPUT" 2>/dev/null || true)
branch=$(git -C "$HOOK_PROJECT" branch --show-current 2>/dev/null || true)
case "$kind" in
  adapter)
    [[ "$stdout" =~ \"id\"[[:space:]]*:[[:space:]]*\"([0-9]+)\" ]] && pr="${BASH_REMATCH[1]}"
    [ -n "$pr" ] || exit 0 ;;
  gh)
    if [[ "$match_seg" =~ (^|[[:space:]])(-R|--repo)([[:space:]]+|=)[\"\']?([^\"\'[:space:]]+) ]]; then
      target="${BASH_REMATCH[4]}"
      if [ -n "$owner" ] && [ -n "$name" ] && [ "${target,,}" != "${owner,,}/${name,,}" ]; then
        note "launch-local-review: gh pr create targets $target, not $owner/$name; no local review launched"; exit 0
      fi
    fi
    [[ "$stdout" =~ /pull/([0-9]+) ]] && pr="${BASH_REMATCH[1]}"
    [ -n "$pr" ] || exit 0 ;;
  az)
    for opt in repository project org organization; do
      if [[ "$match_seg" =~ (^|[[:space:]])--$opt([[:space:]]+|=)[\"\']?([^\"\'[:space:]]+) ]]; then
        target="${BASH_REMATCH[3]}"; want=""
        # shellcheck disable=SC2154 # az_repo, az_project and az_org come from the eval above
        case "$opt" in repository) want="$az_repo" ;; project) want="$az_project" ;; org|organization) want="$az_org" ;; esac
        if [ -n "$want" ] && [ "${target,,}" != "${want,,}" ] && [ "${target%/}" != "${want%/}" ]; then
          note "launch-local-review: az repos pr create targets --$opt $target, not $want; no local review launched"; exit 0
        fi
      fi
    done
    [[ "$stdout" =~ \"pullRequestId\"[[:space:]]*:[[:space:]]*([0-9]+) ]] && pr="${BASH_REMATCH[1]}"
    [ -n "$pr" ] || exit 0 ;;
  push)
    trigger=push
    rest="${match_seg#git}"; rest="${rest#"${rest%%[![:space:]]*}"}"; rest="${rest#push}"
    read -r -a ptoks <<<"$rest"
    remote=""
    for t in "${ptoks[@]+"${ptoks[@]}"}"; do
      case "$t" in
        --dry-run|--delete|-d|--all|--mirror|--tags) exit 0 ;;
        :*) exit 0 ;;
        -*) continue ;;
        *) [ -n "$remote" ] || remote="$t" ;;
      esac
    done
    [ -n "$branch" ] || exit 0
    map=$(bash "$STATUS" get --map "$branch" 2>/dev/null) || exit 0
    pr=$(jq -r '.pr // ""' <<<"$map"); [ -n "$pr" ] || exit 0
    [ -n "$remote" ] || remote=$(git -C "$HOOK_PROJECT" config "branch.$branch.remote" 2>/dev/null || true)
    [ -n "$remote" ] || remote=origin
    head=$(git -C "$HOOK_PROJECT" rev-parse HEAD 2>/dev/null || true)
    rsha=$(git -C "$HOOK_PROJECT" rev-parse -q --verify "refs/remotes/$remote/$branch" 2>/dev/null || true)
    [ -n "$head" ] && [ "$rsha" = "$head" ] || exit 0
    [ "$(jq -r '.last_sha // ""' <<<"$map")" != "$head" ] || exit 0
    newest=$(bash "$STATUS" get --pr "$pr" 2>/dev/null || true)
    if [ -n "$newest" ]; then
      nstate=$(jq -r '.state // ""' <<<"$newest"); nsha=$(jq -r '.head_sha // ""' <<<"$newest")
      if ! bash "$STATUS" is_terminal "$nstate" 2>/dev/null && { [ -z "$nsha" ] || [ "$nsha" = "$head" ]; }; then exit 0; fi
      # head_sha is attached by the review itself, so an unattached launch counts for this head too
      { [ -z "$nsha" ] || [ "$nsha" = "$head" ]; } && bash "$STATUS" is_terminal "$nstate" 2>/dev/null && [ "$nstate" != stale ] && [ "$nstate" != "timeout" ] && [ "$nstate" != abandoned ] && [[ "$nstate" != failed* ]] && exit 0
    fi ;;
esac

# --- 4. record the launch --------------------------------------------------------------------
bash "$STATUS" sweep >/dev/null 2>&1 || true
review_dir="$HOOK_ARTIFACTS/tmp/review"; mkdir -p "$review_dir" 2>/dev/null || exit 0
launch=$(bash "$STATUS" new --branch "$branch" --pr "$pr" --trigger "$trigger" 2>/dev/null) || exit 0
[ -n "$branch" ] && [ "$trigger" = pr_create ] && bash "$STATUS" map --branch "$branch" --pr "$pr" >/dev/null 2>&1
launch_file="$review_dir/launch-$launch.json"
prompt="/ai-sdlc:sdlc-review --launch $launch --pr $pr"
report_hint="$(hook_rel "$HOOK_ARTIFACTS")/verify/<date>-<sha12>-pr${pr}-security.md"
rel_launch=$(hook_rel "$launch_file")

emit() {  # emit <text>: the note the author session sees; always exit 0
  jq -cn --arg c "$1" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
  exit 0
}
manual="Open a terminal in the project and run: claude \"$prompt\""
tail_text="Launch $launch, state file $rel_launch (bash \"\$CLAUDE_PLUGIN_ROOT/scripts/review/status.sh\" get --launch $launch). The report lands at $report_hint and is posted on PR $pr as a comment; wait for state 'posted' before shipping. Do not audit this change in this session (the grader is never the author). Findings are advisory; a human code owner approves. A closed or abandoned review window is detected by status.sh sweep after ${SDLC_REVIEW_STALE_MINUTES:-120} minutes."
fail_launch() {  # fail_launch <state detail> <reason>
  bash "$STATUS" set "$launch" "failed $1" "$2" >/dev/null 2>&1 || true
  note "launch-local-review: $2"
  emit "ai-sdlc: review.runner is local but the review window could not be opened: $2. $manual. $tail_text"
}

# --- 5. locate claude -----------------------------------------------------------------------
# SDLC_CLAUDE_BIN, when set, is authoritative (no fallback); otherwise PATH, then the usual
# install locations.
claude_bin="${SDLC_CLAUDE_BIN:-}"
if [ -z "$claude_bin" ]; then
  claude_bin=$(command -v claude 2>/dev/null || true)
  if [ -z "$claude_bin" ]; then
    for c in "${CLAUDE_CODE_EXECPATH:-}" "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" "${APPDATA:-}/npm/claude"; do
      [ -n "$c" ] || continue
      c=$(sdlc_norm_path "$c")
      [ -f "$c" ] && { claude_bin="$c"; break; }
    done
  fi
fi
[ -n "$claude_bin" ] && [ -f "$claude_bin" ] || fail_launch no-claude "the 'claude' command was not found (${claude_bin:-not on PATH}); set SDLC_CLAUDE_BIN or add it to PATH"

# --- 6. the launcher script -------------------------------------------------------------------
sq() { local s="$1"; s="${s//\'/\'\\\'\'}"; printf "'%s'" "$s"; }
keep_always=" CLAUDE_CONFIG_DIR CLAUDE_CODE_GIT_BASH_PATH CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY "
unsets=()
while IFS= read -r v; do
  [ -n "$v" ] || continue
  case "$v" in CLAUDE*) case "$keep_always" in *" $v "*) ;; *) unsets+=("$v") ;; esac ;; esac
done < <(compgen -e 2>/dev/null || true)
# session state that is never exported by name but would mark the child as a nested session
for v in CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID; do
  case " ${unsets[*]+"${unsets[*]}"} " in *" $v "*) ;; *) unsets+=("$v") ;; esac
done
add_unset() { local v; for v in "$@"; do case " ${unsets[*]+"${unsets[*]}"} " in *" $v "*) ;; *) unsets+=("$v") ;; esac; done; }
if [ "${auth:-login}" = login ]; then
  while IFS= read -r v; do [ -n "$v" ] && add_unset "$v"; done < <(compgen -e ANTHROPIC_ 2>/dev/null || true)
  add_unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
fi
ext='sh'; case "${OSTYPE:-}" in darwin*) ext='command' ;; esac
script="$review_dir/launch-$launch.$ext"
{
  printf '#!/usr/bin/env bash\n'
  printf '# ai-sdlc local review launcher for launch %s (PR %s). Written by hooks/launch-local-review.sh.\n' "$launch" "$pr"
  printf 'STATUS=%s\n' "$(sq "$STATUS")"
  printf 'bash "$STATUS" set %s started "terminal window opened" >/dev/null 2>&1\n' "$(sq "$launch")"
  printf '# policy A: session state of the launching Claude Code session is never inherited\n'
  [ ${#unsets[@]} -gt 0 ] && printf 'unset %s\n' "${unsets[*]}"
  if [ "${auth:-login}" = login ]; then printf '# policy B (review.localAuth login): no API key or provider switch reaches the reviewer; it uses the /login credentials\n'; else printf '# review.localAuth inherit: authentication and provider variables are kept\n'; fi
  printf 'finish() {\n  rc=$?\n  st=$(bash "$STATUS" get --launch %s --field state 2>/dev/null)\n' "$(sq "$launch")"
  printf '  if ! bash "$STATUS" is_terminal "$st" 2>/dev/null; then\n'
  printf '    if [ "$rc" -eq 0 ]; then bash "$STATUS" set %s abandoned "claude exited 0 in state $st without finishing the review" >/dev/null 2>&1; else bash "$STATUS" set %s "failed claude exited $rc" "claude exited $rc in state $st" >/dev/null 2>&1; fi\n' "$(sq "$launch")" "$(sq "$launch")"
  printf '    echo "ai-sdlc: the review did not finish (claude exited $rc in state $st). Press Enter to close." >&2; read -r _\n  fi\n}\n'
  printf 'trap finish EXIT HUP TERM\n'
  printf 'cd %s || { echo "ai-sdlc: cannot cd to the project" >&2; read -r _; exit 1; }\n' "$(sq "$HOOK_PROJECT")"
  printf '%s %s\n' "$(sq "$claude_bin")" "$(sq "$prompt")"
} >"$script" || fail_launch launcher-write "cannot write the launcher script $script"
chmod +x "$script" 2>/dev/null || true
jq -c --arg l "$script" '.launcher=$l' "$launch_file" >"$launch_file.tmp" 2>/dev/null && mv -f "$launch_file.tmp" "$launch_file"

# --- 7. open the terminal, detached ------------------------------------------------------------
title="ai-sdlc review PR $pr"
launch_cmd=()
term="${SDLC_REVIEW_TERMINAL:-}"
if [ -n "${launcher_tpl:-}" ] && [ -z "$term" ]; then
  tpl="${launcher_tpl//\{script\}/$script}"; tpl="${tpl//\{cwd\}/$HOOK_PROJECT}"; tpl="${tpl//\{title\}/$title}"
  launch_cmd=(bash -c "$tpl"); term=custom
fi
if [ -z "$term" ]; then
  case "${OSTYPE:-}" in
    msys*|cygwin*|win32*) if sdlc_has wt.exe; then term=wt; else term=cmd; fi ;;
    darwin*) term=open ;;
    *) for t in x-terminal-emulator gnome-terminal konsole xterm; do sdlc_has "$t" && { term="$t"; break; }; done ;;
  esac
fi
to_win() { if sdlc_has cygpath; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
case "$term" in
  custom) ;;
  wt)
    bash_exe=$(command -v bash); launch_cmd=(wt.exe -d "$(to_win "$HOOK_PROJECT")" --title "$title" "$(to_win "$bash_exe")" --login "$(to_win "$script")") ;;
  cmd)
    bash_exe=$(command -v bash); launch_cmd=(cmd //c start "$title" "$(to_win "$bash_exe")" --login "$(to_win "$script")") ;;
  open) launch_cmd=(open -a Terminal "$script") ;;
  osascript) launch_cmd=(osascript -e "tell application \"Terminal\" to do script \"bash '$script'\"") ;;
  x-terminal-emulator) launch_cmd=(x-terminal-emulator -T "$title" -e bash "$script") ;;
  gnome-terminal) launch_cmd=(gnome-terminal --title="$title" -- bash "$script") ;;
  konsole) launch_cmd=(konsole --title "$title" -e bash "$script") ;;
  xterm) launch_cmd=(xterm -T "$title" -e bash "$script") ;;
  none|"") fail_launch no-terminal "no terminal emulator found to open the review window (set review.localLauncher or SDLC_REVIEW_TERMINAL)" ;;
  *) fail_launch no-terminal "unknown SDLC_REVIEW_TERMINAL '$term'" ;;
esac

if [ "${SDLC_LAUNCH_DRY_RUN:-0}" = 1 ]; then
  note "launch: ${launch_cmd[*]}"
  emit "ai-sdlc: review.runner is local: a review window would open running $prompt (dry run, nothing launched). $tail_text"
fi
# Detached: every fd redirected so no pipe keeps Claude Code waiting past the hook timeout; the
# acknowledgement poll below, not the exit code, tells whether a window actually started.
if sdlc_has setsid; then setsid "${launch_cmd[@]}" </dev/null >/dev/null 2>&1 & else "${launch_cmd[@]}" </dev/null >/dev/null 2>&1 & fi
disown 2>/dev/null || true

# --- 8. acknowledgement: did the launcher start? ------------------------------------------------
acked=0
for _ in 1 2 3 4 5 6; do
  st=""; c=$(<"$launch_file") 2>/dev/null || true
  [[ "$c" =~ \"state\":\"([^\"]*)\" ]] && st="${BASH_REMATCH[1]}"
  [ -n "$st" ] && [ "$st" != requested ] && { acked=1; break; }
  sleep 0.5
done
if [ $acked = 1 ]; then
  emit "ai-sdlc: review.runner is local: a separate terminal window opened running $prompt (fresh session with your own Claude login; this session's state was not inherited). $tail_text"
fi
emit "ai-sdlc: review.runner is local: a terminal window running $prompt was requested but has not acknowledged yet (state requested). If no window appeared: $manual. $tail_text"
