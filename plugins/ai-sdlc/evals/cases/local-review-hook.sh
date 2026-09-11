#!/usr/bin/env bash
# launch-local-review.sh (PostToolUse) with review.runner local: launches only for the supported
# command subset with an id on stdout (or an unreviewed synchronised commit on git push), never
# denies, records the launch lifecycle, writes a launcher that strips the session state (and the
# auth/provider variables under localAuth login), and reports every launch failure in the note.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
H="$P/hooks/launch-local-review.sh"; ST="$P/scripts/review/status.sh"

bare="$EVAL_TMP/origin.git"; git init -q --bare -b main "$bare"
proj="$EVAL_TMP/proj"; git clone -q "$bare" "$proj" 2>/dev/null
git -C "$proj" config user.email e@x; git -C "$proj" config user.name e; git -C "$proj" config core.autocrlf false
cat >"$proj/sdlc.config.json" <<'JSON'
{"version":1,"platform":"github","tier":3,"repo":{"owner":"mock-org","name":"mock-repo","defaultBranch":"main"},
 "commands":{"verify":"true"},"review":{"runner":"local","nitCap":5},"artifacts":{"dir":".sdlc"},
 "azure":{"organization":"https://dev.azure.com/mock-org","project":"mock-proj","repo":"mock-repo"}}
JSON
printf '.sdlc/tmp/\n' >"$proj/.gitignore"; printf 'a\n' >"$proj/a.txt"
git -C "$proj" add -A >/dev/null; git -C "$proj" commit -q -m init; git -C "$proj" push -q origin main 2>/dev/null
git -C "$proj" checkout -q -b feat/x; printf 'b\n' >"$proj/b.txt"; git -C "$proj" add -A; git -C "$proj" commit -q -m feat
git -C "$proj" push -q -u origin feat/x 2>/dev/null
head=$(git -C "$proj" rev-parse HEAD)
cd "$proj" || exit 1
fake="$EVAL_TMP/fake"; mkdir -p "$fake"; printf '#!/usr/bin/env bash\nexit 0\n' >"$fake/claude"; chmod +x "$fake/claude"
export SDLC_LAUNCH_DRY_RUN=1 SDLC_REVIEW_TERMINAL=wt SDLC_CLAUDE_BIN="$fake/claude" ANTHROPIC_API_KEY=sk-test CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=s1 CLAUDE_CONFIG_DIR=/cfg

post() {  # post <tool> <command> <stdout> [event] -> PostToolUse JSON
  jq -cn --arg t "$1" --arg c "$2" --arg o "$3" --arg e "${4:-PostToolUse}" --arg cwd "$proj" \
    '{session_id:"eval",cwd:$cwd,hook_event_name:$e,tool_name:$t,tool_input:{command:$c},tool_response:{stdout:$o,stderr:"",interrupted:false}}'
}
ctx() { jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$HOOK_OUT" 2>/dev/null; }
newest_launch() { ls -t "$proj/.sdlc/tmp/review"/launch-*.json 2>/dev/null | head -n1; }
silent() { local label="$1"; shift; run_hook "$H" "$1"; [ "$HOOK_EXIT" = 0 ] && [ -z "$HOOK_OUT$HOOK_ERR" ] && _ok "$label: silent exit 0" || _fail "$label: not silent" "exit $HOOK_EXIT out ${HOOK_OUT:0:120} err ${HOOK_ERR:0:120}"; }
launched() {  # launched <label> <json> <pr>
  run_hook "$H" "$2"
  assert_eq "0" "$HOOK_EXIT" "$1: exit 0"
  assert_eq "PostToolUse" "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$HOOK_OUT" 2>/dev/null)" "$1: note is a PostToolUse additionalContext"
  assert_match "sdlc-review --launch [0-9TZ-]+ --pr $3( |\")" "$(ctx)" "$1: note names /ai-sdlc:sdlc-review --pr $3"
  assert_match "pr$3-security\\.md" "$(ctx)" "$1: note names the expected report"
  assert_match 'ai-sdlc: launch: wt\.exe .*--login' "$HOOK_ERR" "$1: dry run prints the wt.exe launch command"
}

echo "-- pr creation through the adapter"
launched "adapter pr_create" "$(post Bash 'sdlc-platform pr_create "feat: x" body.md main feat/x' '{"id":"42","url":"https://github.com/mock-org/mock-repo/pull/42","platform":"github"}')" 42
lf=$(newest_launch)
assert_eq "requested" "$(jq -r .state "$lf")" "launch recorded as requested (dry run never starts it)"
assert_eq "42 feat/x pr_create" "$(jq -r '"\(.pr) \(.branch) \(.trigger)"' "$lf")" "launch carries pr, branch and trigger"
assert_eq "42" "$(bash "$ST" get --map feat/x --field pr)" "branch feat/x is mapped to PR 42"
script=$(jq -r .launcher "$lf"); assert_file "$script" "launcher script written"
assert_match "sdlc-review --launch $(jq -r .launch_id "$lf") --pr 42" "$(cat "$script")" "launcher runs the review command"
assert_match 'unset [^\n]*CLAUDECODE' "$(cat "$script")" "policy A: CLAUDECODE unset"
assert_match 'unset [^\n]*CLAUDE_CODE_SESSION_ID' "$(cat "$script")" "policy A: CLAUDE_CODE_SESSION_ID unset"
assert_match 'unset [^\n]*ANTHROPIC_API_KEY' "$(cat "$script")" "policy B (login): ANTHROPIC_API_KEY unset"
assert_not_match 'unset [^\n]*CLAUDE_CONFIG_DIR' "$(cat "$script")" "CLAUDE_CONFIG_DIR is kept"
assert_match "set '[^']+' started" "$(cat "$script")" "launcher acknowledges with state started"
assert_match "'$fake/claude' '/ai-sdlc:sdlc-review" "$(cat "$script")" "launcher calls the configured claude"
first_id=$(jq -r .launch_id "$lf")
launched "second creation" "$(post Bash 'sdlc-platform pr_create t b main feat/x' '{"id":"43","url":"u","platform":"github"}')" 43
[ "$(jq -r .launch_id "$(newest_launch)")" != "$first_id" ] && _ok "each launch has its own id and files" || _fail "launch id reused" ""

echo "-- localAuth inherit keeps the auth variables"
jq '.review.localAuth="inherit"' sdlc.config.json >c.json && mv c.json sdlc.config.json
launched "inherit" "$(post Bash 'gh pr create --title x' 'https://github.com/mock-org/mock-repo/pull/60')" 60
s2=$(jq -r .launcher "$(newest_launch)")
assert_match 'unset [^\n]*CLAUDECODE' "$(cat "$s2")" "inherit: session state still unset"
assert_not_match 'ANTHROPIC_API_KEY' "$(cat "$s2")" "inherit: ANTHROPIC_API_KEY kept"
jq 'del(.review.localAuth)' sdlc.config.json >c.json && mv c.json sdlc.config.json

echo "-- gh / az / PowerShell forms"
launched "gh pr create url" "$(post Bash 'gh pr create --title x --body y' 'https://github.com/mock-org/mock-repo/pull/44')" 44
launched "gh -R same repo, quoted" "$(post Bash 'gh pr create -R "mock-org/mock-repo" --title x' 'https://github.com/mock-org/mock-repo/pull/45')" 45
launched "az repos pr create" "$(post Bash 'az repos pr create --title x -o json' '{"pullRequestId": 7, "title": "x"}')" 7
launched "PowerShell tool" "$(post PowerShell 'gh pr create --title x' 'https://github.com/mock-org/mock-repo/pull/46')" 46
launched "env prefix and chained" "$(post Bash 'FOO=1 gh pr create --title x && echo done' 'https://github.com/mock-org/mock-repo/pull/47')" 47
run_hook "$H" "$(post Bash 'gh pr create --repo other/repo --title x' 'https://github.com/other/repo/pull/1')"
assert_eq "0" "$HOOK_EXIT" "gh --repo other: exit 0"; assert_eq "" "$HOOK_OUT" "gh --repo other: no launch"; assert_match 'targets other/repo' "$HOOK_ERR" "gh --repo other: stderr note"
run_hook "$H" "$(post Bash 'az repos pr create --repository other-repo' '{"pullRequestId": 8}')"
assert_eq "" "$HOOK_OUT" "az --repository other: no launch"; assert_match 'targets --repository other-repo' "$HOOK_ERR" "az --repository other: stderr note"

echo "-- never launches"
silent "quoted text in a commit message" "$(post Bash 'git commit -m "x && gh pr create"' '')"
silent "echo of the command" "$(post Bash 'echo "gh pr create"' '')"
silent "command substitution" "$(post Bash 'x=$(gh pr create --title y)' 'https://github.com/mock-org/mock-repo/pull/99')"
silent "pr_create without an id on stdout" "$(post Bash 'sdlc-platform pr_create t b main x' '')"
silent "gh pr create without a URL" "$(post Bash 'gh pr create' 'aborted')"
silent "--dry-run creation" "$(post Bash 'sdlc-platform --dry-run pr_create t b main x' '{"id":"9"}')"
silent "SDLC_PLATFORM_MOCK creation" "$(post Bash 'SDLC_PLATFORM_MOCK=1 sdlc-platform pr_create t b main x' '{"id":"9"}')"
silent "pr_get" "$(post Bash 'sdlc-platform pr_get 42' '{"id":"42"}')"
silent "PreToolUse event" "$(post Bash 'sdlc-platform pr_create t b main x' '{"id":"9"}' PreToolUse)"
silent "Edit tool" "$(jq -cn --arg cwd "$proj" '{cwd:$cwd,hook_event_name:"PostToolUse",tool_name:"Edit",tool_input:{file_path:"a"},tool_response:"ok"}')"
silent "not JSON (fail open)" 'not json'
jq '.review.runner="ci"' sdlc.config.json >c.json && mv c.json sdlc.config.json
silent "runner ci" "$(post Bash 'sdlc-platform pr_create t b main x' '{"id":"9"}')"
jq '.review.runner="local" | .platform="none"' sdlc.config.json >c.json && mv c.json sdlc.config.json
silent "platform none" "$(post Bash 'gh pr create' 'https://github.com/mock-org/mock-repo/pull/1')"
jq '.platform="github"' sdlc.config.json >c.json && mv c.json sdlc.config.json

echo "-- git push: unreviewed synchronised commit detection"
for f in .sdlc/tmp/review/launch-*.json; do bash "$ST" set "$(jq -r .launch_id "$f")" timeout eval >/dev/null; done
git fetch -q origin
bash "$ST" map --branch feat/x --pr 42 --sha 0000000000000000000000000000000000000000
launched "push origin feat/x (remote ref == HEAD, unreviewed)" "$(post Bash 'git push origin feat/x' '')" 42
assert_eq "push" "$(jq -r .trigger "$(newest_launch)")" "push launch carries trigger push"
silent "push again while that launch is live" "$(post Bash 'git push origin feat/x' '')"
bash "$ST" set "$(jq -r .launch_id "$(newest_launch)")" timeout eval >/dev/null
launched "bare git push resolves the branch remote" "$(post Bash 'git push' '')" 42
bash "$ST" set "$(jq -r .launch_id "$(newest_launch)")" posted eval >/dev/null
silent "push of a sha whose review is posted" "$(post Bash 'git push origin feat/x' '')"
bash "$ST" map --branch feat/x --pr 42 --sha "$head"
silent "push of the last reviewed sha" "$(post Bash 'git push origin feat/x' '')"
bash "$ST" map --branch feat/x --pr 42 --sha 0000000000000000000000000000000000000000
silent "git -C dir push (global options unsupported)" "$(post Bash 'git -C . push origin feat/x' '')"
silent "push --delete" "$(post Bash 'git push origin --delete feat/x' '')"
silent "push :refspec" "$(post Bash 'git push origin :feat/x' '')"
silent "push --dry-run" "$(post Bash 'git push --dry-run origin feat/x' '')"
printf 'c\n' >c.txt; git add c.txt; git commit -q -m c
silent "push when the remote ref is not HEAD" "$(post Bash 'git push origin feat/x' '')"
git reset -q --hard "$head"
git checkout -q main
silent "push from a branch without a mapping" "$(post Bash 'git push origin main' '')"
git checkout -q feat/x

echo "-- launch failures are reported, never denied"
SDLC_REVIEW_TERMINAL=none run_hook "$H" "$(post Bash 'gh pr create' 'https://github.com/mock-org/mock-repo/pull/70')"
assert_eq "0" "$HOOK_EXIT" "no terminal: exit 0"
assert_match 'could not be opened' "$(ctx)" "no terminal: note says the window could not be opened"
assert_match 'claude "/ai-sdlc:sdlc-review --launch [0-9TZ-]+ --pr 70"' "$(ctx)" "no terminal: note carries the manual command"
assert_eq "failed no-terminal" "$(jq -r .state "$(newest_launch)")" "no terminal: state failed no-terminal"
SDLC_CLAUDE_BIN=/nonexistent/claude run_hook "$H" "$(post Bash 'gh pr create' 'https://github.com/mock-org/mock-repo/pull/71')"
assert_eq "0" "$HOOK_EXIT" "no claude: exit 0"
assert_eq "failed no-claude" "$(jq -r .state "$(newest_launch)")" "no claude: state failed no-claude"
assert_match 'was not found' "$(ctx)" "no claude: note explains"
jq '.review.localLauncher="mylaunch {title} {script}"' sdlc.config.json >c.json && mv c.json sdlc.config.json
SDLC_REVIEW_TERMINAL= run_hook "$H" "$(post Bash 'gh pr create' 'https://github.com/mock-org/mock-repo/pull/72')"
assert_match 'launch: bash -c mylaunch ai-sdlc review PR 72 .*launch-.*\.sh' "$HOOK_ERR" "review.localLauncher template is used"
jq 'del(.review.localLauncher)' sdlc.config.json >c.json && mv c.json sdlc.config.json
for t in cmd open x-terminal-emulator gnome-terminal konsole xterm; do
  SDLC_REVIEW_TERMINAL=$t run_hook "$H" "$(post Bash 'gh pr create' 'https://github.com/mock-org/mock-repo/pull/73')"
  case "$t" in cmd) want='launch: cmd //c start' ;; open) want='launch: open -a Terminal' ;; *) want="launch: $t " ;; esac
  assert_match "$want" "$HOOK_ERR" "SDLC_REVIEW_TERMINAL=$t builds the $t command"
done

echo "-- the launcher records how the session ended"
run_hook "$H" "$(post Bash 'gh pr create' 'https://github.com/mock-org/mock-repo/pull/80')"
lf=$(newest_launch); id=$(jq -r .launch_id "$lf"); script=$(jq -r .launcher "$lf")
printf '#!/usr/bin/env bash\nexit 7\n' >"$fake/claude"
echo | bash "$script" >/dev/null 2>&1
assert_eq "failed claude exited 7" "$(jq -r .state "$lf")" "claude exit 7 -> failed claude exited 7"
assert_match 'started' "$(jq -r '[.history[].state] | join(",")' "$lf")" "launcher acknowledged with started before claude ran"
run_hook "$H" "$(post Bash 'gh pr create' 'https://github.com/mock-org/mock-repo/pull/81')"
lf=$(newest_launch); script=$(jq -r .launcher "$lf")
printf '#!/usr/bin/env bash\nexit 0\n' >"$fake/claude"
echo | bash "$script" >/dev/null 2>&1
assert_eq "abandoned" "$(jq -r .state "$lf")" "claude exit 0 without finishing -> abandoned"
run_hook "$H" "$(post Bash 'gh pr create' 'https://github.com/mock-org/mock-repo/pull/82')"
lf=$(newest_launch); id=$(jq -r .launch_id "$lf"); script=$(jq -r .launcher "$lf")
printf '#!/usr/bin/env bash\nbash "%s" set "%s" posted done\nexit 0\n' "$ST" "$id" >"$fake/claude"
echo | bash "$script" >/dev/null 2>&1
assert_eq "posted" "$(jq -r .state "$lf")" "a finished review keeps its terminal state"
printf '#!/usr/bin/env bash\nunset -v CLAUDECODE 2>/dev/null; env | grep -E "^(CLAUDECODE|CLAUDE_CODE_SESSION_ID|ANTHROPIC_API_KEY)=" | wc -l > "%s/envcount"\nbash "%s" set "%s" posted done\n' "$EVAL_TMP" "$ST" "$id" >"$fake/claude"
bash "$ST" set "$id" running >/dev/null
echo | bash "$script" >/dev/null 2>&1
assert_eq "0" "$(tr -d ' \r\n' <"$EVAL_TMP/envcount")" "the reviewer session sees none of the stripped variables"

echo "-- sweep"
run_hook "$H" "$(post Bash 'gh pr create' 'https://github.com/mock-org/mock-repo/pull/90')"
lf=$(newest_launch)
jq '.updated_epoch = 1' "$lf" >"$lf.tmp" && mv "$lf.tmp" "$lf"
bash "$ST" sweep
assert_eq "timeout" "$(jq -r .state "$lf")" "an old requested launch becomes timeout"
run_hook "$H" "$(post Bash 'gh pr create' 'https://github.com/mock-org/mock-repo/pull/91')"
lf=$(newest_launch); bash "$ST" set "$(jq -r .launch_id "$lf")" running >/dev/null
jq '.updated_epoch = 1' "$lf" >"$lf.tmp" && mv "$lf.tmp" "$lf"
bash "$ST" sweep
assert_eq "abandoned" "$(jq -r .state "$lf")" "an old running launch becomes abandoned"
eval_done
