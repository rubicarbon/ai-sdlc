#!/usr/bin/env bash
# Unit tests for .claude/hooks/guard-repo-boundary.sh
# Usage: bash .dev/boundary-tests.sh
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
hook="$here/.claude/hooks/guard-repo-boundary.sh"
pass=0; fail=0
win_root=$(cd "$here" && pwd -W 2>/dev/null || echo "$here")

run() { # run <expected-exit> <tool> <json-tool_input> <label>
  local want="$1" tool="$2" ti="$3" label="$4" got err
  err=$(printf '{"session_id":"t","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":%s}' "$here" "$tool" "$ti" | bash "$hook" 2>&1 >/dev/null); got=$?
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   %-4s %s\n' "$got" "$label"
  else fail=$((fail+1)); printf 'FAIL want=%s got=%s %s\n     %s\n' "$want" "$got" "$label" "$err"; fi
}
j() { jq -cn --arg v "$1" "$2"; }   # helper: build tool_input json

echo "== file tools: denied =="
run 2 Read  "$(j "$HOME/.claude/settings.json" '{file_path:$v}')"            'Read ~/.claude/settings.json (posix)'
run 2 Read  "$(j 'C:\Users\someone\.claude\settings.json' '{file_path:$v}')" 'Read C:\Users\... (windows)'
run 2 Read  "$(j '/c/Windows/win.ini' '{file_path:$v}')"                    'Read /c/Windows/win.ini'
run 2 Edit  "$(j "$here/../sibling/x.txt" '{file_path:$v}')"                'Edit ../sibling via ..'
run 2 Write "$(j '/tmp/x' '{file_path:$v}')"                                'Write /tmp/x'
run 2 Glob  "$(j "$HOME" '{pattern:"**/*.json",path:$v}')"                  'Glob path=~'
run 2 Grep  "$(j 'C:\Projects' '{pattern:"x",path:$v}')"                    'Grep path=C:\Projects (parent)'
run 2 NotebookEdit "$(j '/d/nb.ipynb' '{notebook_path:$v}')"                'NotebookEdit /d/nb.ipynb'
run 2 Read  "$(j '\\server\share\f' '{file_path:$v}')"                      'Read UNC path'

echo "== file tools: allowed =="
run 0 Read  "$(j "$here/README.md" '{file_path:$v}')"                        'Read in-repo posix'
run 0 Read  "$(j "$win_root\\README.md" '{file_path:$v}')"                   'Read in-repo windows path'
run 0 Edit  "$(j "$here/plugins/../docs/x.md" '{file_path:$v}')"            'Edit in-repo with .. staying inside'
run 0 Glob  '{"pattern":"**/*.sh"}'                                          'Glob without path'
run 0 Grep  '{"pattern":"TODO"}'                                             'Grep without path'

echo "== shell: denied =="
run 2 Bash "$(j 'cat ~/.claude/settings.json' '{command:$v}')"               'cat ~/...'
run 2 Bash "$(j 'cat $HOME/.bashrc' '{command:$v}')"                         'cat $HOME/...'
run 2 Bash "$(j 'ls %USERPROFILE%' '{command:$v}')"                          'ls %USERPROFILE%'
run 2 Bash "$(j 'cd .. && ls' '{command:$v}')"                               'cd .. && ls'
run 2 Bash "$(j 'cd plugins && cd ../.. && ls' '{command:$v}')"              'cd in then out'
run 2 Bash "$(j 'cd /tmp; ls' '{command:$v}')"                               'cd /tmp; ls'
run 2 Bash "$(j 'cd' '{command:$v}')"                                        'bare cd (home)'
run 2 Bash "$(j 'cd -' '{command:$v}')"                                      'cd -'
run 2 Bash "$(j 'git -C C:\Other status' '{command:$v}')"                    'git -C C:\Other'
run 2 Bash "$(j 'git -C ../other log' '{command:$v}')"                       'git -C ../other'
run 2 Bash "$(j 'git worktree add ../wt feature' '{command:$v}')"            'git worktree add ../wt'
run 2 Bash "$(j 'git --git-dir=/c/Other/.git log' '{command:$v}')"           'git --git-dir=/c/Other/.git'
run 2 Bash "$(j 'cat ../../etc/hosts' '{command:$v}')"                       'cat ../../etc/hosts'
run 2 Bash "$(j 'bash -c "cat ~/.ssh/id_rsa"' '{command:$v}')"               'bash -c "cat ~/.ssh/id_rsa"'
run 2 Bash "$(j 'echo $(cat /etc/passwd)' '{command:$v}')"                   'subshell cat /etc/passwd'
run 2 Bash "$(j 'ls "C:\Program Files"' '{command:$v}')"                     'ls "C:\Program Files"'
run 2 Bash "$(j 'cp x.txt /c/Users/me/x.txt' '{command:$v}')"                'cp to /c/Users'
run 2 Bash "$(j 'ln -s /c/Users/me/secret link' '{command:$v}')"             'ln -s outside target'
run 2 Bash "$(j 'echo hi > ../out.txt' '{command:$v}')"                      'redirect > ../out.txt'
run 2 Bash "$(j 'echo hi >/tmp/out.txt' '{command:$v}')"                     'redirect >/tmp/out.txt'
run 2 Bash "$(j 'tar -C / -xf x.tgz' '{command:$v}')"                        'tar -C /'
run 2 Bash "$(j 'find / -name x' '{command:$v}')"                            'find /'
run 2 Bash "$(j 'ls --directory=/etc' '{command:$v}')"                       '--opt=/etc'
run 2 Bash "$(j 'FOO=/etc/passwd cat $FOO' '{command:$v}')"                  'VAR=/outside assignment'
run 2 Bash "$(j 'npx foo --out $TMPDIR/x' '{command:$v}')"                   '$TMPDIR'
run 2 PowerShell "$(j 'Get-Content C:\Users\x\secret.txt' '{command:$v}')"   'PS Get-Content C:\Users'
run 2 PowerShell "$(j 'Set-Location ..; ls' '{command:$v}')"                 'PS Set-Location ..'
run 2 PowerShell "$(j 'cat $env:USERPROFILE\.claude\settings.json' '{command:$v}')" 'PS $env:USERPROFILE'
run 2 PowerShell "$(j 'Get-ChildItem ~' '{command:$v}')"                     'PS ~'

echo "== shell: allowed =="
run 0 Bash "$(j 'ls -la' '{command:$v}')"                                    'ls -la'
run 0 Bash "$(j 'git status && git log --oneline -5' '{command:$v}')"         'git status'
run 0 Bash "$(j 'cd plugins/ai-sdlc && ls' '{command:$v}')"                  'cd inside'
run 0 Bash "$(j 'cd plugins && cd .. && ls' '{command:$v}')"                 'cd in and back to root'
run 0 Bash "$(j 'cat plugins/../README.md' '{command:$v}')"                  '.. staying inside'
run 0 Bash "$(j 'curl -sS https://api.github.com/repos/x/y | jq .' '{command:$v}')" 'curl URL'
run 0 Bash "$(j 'echo hi > /dev/null 2>&1' '{command:$v}')"                  '/dev/null redirect'
run 0 Bash "$(j 'mkdir -p .dev/scratch/gh && cd .dev/scratch/gh && git init' '{command:$v}')" 'scratch repo init'
run 0 Bash "$(j 'chmod +x .claude/hooks/guard-repo-boundary.sh' '{command:$v}')" 'chmod in repo'
run 0 Bash "$(j 'grep -rn "TODO" --exclude-dir=templates .' '{command:$v}')" 'grep with . path'
run 0 Bash "$(j 'node --version; python --version' '{command:$v}')"          'version checks'
run 0 Bash "$(j 'printf "%s\n" a b | sort -u' '{command:$v}')"               'printf with %s (not %VAR%)'
run 0 PowerShell "$(j 'Get-ChildItem .\plugins' '{command:$v}')"             'PS in-repo relative'

echo "== arithmetic false positives (allowed) =="
run 0 Bash "$(j 'echo $(( (e - s) / 1000000 ))' '{command:$v}')"             'division with spaces'
run 0 Bash "$(j 'x=$((a / b))' '{command:$v}')"                              'division by identifier'
run 2 Bash "$(j 'ls / ' '{command:$v}')"                                     'ls / (trailing space)'

echo "== fail closed on bad input =="
echo 'not json' | bash "$hook" >/dev/null 2>&1; got=$?
if [ "$got" = 2 ]; then pass=$((pass+1)); echo "ok   2    malformed JSON input denies"; else fail=$((fail+1)); echo "FAIL want=2 got=$got malformed JSON input"; fi
printf '' | bash "$hook" >/dev/null 2>&1; got=$?
if [ "$got" = 2 ]; then pass=$((pass+1)); echo "ok   2    empty input denies"; else fail=$((fail+1)); echo "FAIL want=2 got=$got empty input"; fi

echo "== timing =="
# Process spawn is expensive under MSYS; report the hook relative to a bash+jq baseline.
# Minimum of 5 runs filters antivirus / scheduler jitter.
min_ms() { local best=999999 s e d; for _ in 1 2 3 4 5; do s=$(date +%s%N); "$@" >/dev/null 2>&1; e=$(date +%s%N); d=$(( (e - s) / 1000000 )); [ "$d" -lt "$best" ] && best=$d; done; echo "$best"; }
base_run() { bash -c 'true'; echo '{}' | jq . ; }
hook_run() { printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"ls -la plugins && git status"}}' "$here" | bash "$hook"; }
base=$(min_ms base_run); best=$(min_ms hook_run)
echo "hook time (min of 5): ${best} ms; bash+jq spawn baseline on this machine: ${base} ms; hook logic overhead: $(( best - base )) ms (limit 100)"
if [ $(( best - base )) -le 100 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL timing"; fi

echo; echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
