#!/usr/bin/env bash
# Every plugin hook exits 0 with no output, fast, in a repository that is not an sdlc project.
. "${EVAL_ROOT}/_assert.sh"
P="$SDLC_PLUGIN_ROOT_FOR_EVALS"
plain="$EVAL_TMP/plain"; mkdir -p "$plain/src"; git -C "$plain" init -q -b main; printf 'x\n' >"$plain/src/a.ts"
cd "$plain" || exit 1

inputs=(
  "$(hook_json Edit '{"file_path":"'"$plain"'/src/a.ts","old_string":"x","new_string":"y"}' "$plain")"
  "$(hook_json Read '{"file_path":"'"$plain"'/.env"}' "$plain")"
  "$(hook_json Bash '{"command":"git push origin main && cat ~/.ssh/id_rsa > out.txt"}' "$plain")"
)
for hook in "$P"/hooks/*.sh; do
  name="${hook##*/}"
  for inp in "${inputs[@]}"; do
    run_hook "$hook" "$inp"
    assert_eq "0" "$HOOK_EXIT" "$name exits 0 outside an sdlc project"
    assert_eq "" "$HOOK_OUT$HOOK_ERR" "$name prints nothing outside an sdlc project"
  done
done

# timing: the silent path is bash startup plus builtins
min_ms() { local best=999999 s e d; for _ in 1 2 3 4 5; do s=$(date +%s%N); "$@" >/dev/null 2>&1; e=$(date +%s%N); d=$(( (e - s) / 1000000 )); [ "$d" -lt "$best" ] && best=$d; done; echo "$best"; }
base=$(min_ms bash -c 'true')
one_hook() { bash "$1" <<<"$2"; }
for hook in "$P"/hooks/*.sh; do
  name="${hook##*/}"
  t=$(min_ms one_hook "$hook" "${inputs[0]}")
  over=$(( t - base ))
  echo "  info  $name: ${t} ms (bash startup ${base} ms, overhead ${over} ms)"
  if [ "$over" -le 80 ]; then _ok "$name silent path overhead under 80 ms"; else _fail "$name too slow" "$over ms over bash startup"; fi
done

# executable bits and shebangs
for hook in "$P"/hooks/*.sh; do
  [ -x "$hook" ] && _ok "${hook##*/} is executable" || _fail "${hook##*/} not executable" ""
  [ "$(head -n1 "$hook")" = "#!/usr/bin/env bash" ] && _ok "${hook##*/} has a bash shebang" || _fail "${hook##*/} shebang" "$(head -n1 "$hook")"
done
# hooks.json has the outer wrapper and every script it names exists
jq -e '.hooks.PreToolUse and (.hooks.PostToolUse | length == 1) and (.hooks.PostToolUse[0].matcher == "Bash|PowerShell") and (.hooks.PostToolUse[0].hooks[0].args[0] | endswith("launch-local-review.sh"))' "$P/hooks/hooks.json" >/dev/null && _ok 'hooks.json has the outer "hooks" wrapper, the PreToolUse guards and one PostToolUse launcher on Bash|PowerShell' || _fail "hooks.json wrapper" ""
assert_eq "5" "$(ls "$P"/hooks/*.sh | wc -l | tr -d ' ')" "five hook scripts ship with the plugin"
while IFS= read -r s; do f="$P/${s#\$\{CLAUDE_PLUGIN_ROOT\}/}"; [ -f "$f" ] && _ok "hooks.json references existing ${s##*/}" || _fail "hooks.json references missing script" "$s"; done < <(jq -r '.hooks[][].hooks[].args[0]' "$P/hooks/hooks.json")
eval_done
