# VERIFY.md — steps only the repository owner can run

The build session could not install the plugin locally (no access outside the repo) and could not open another repository. These steps prove installation and runtime registration. Run them from a normal Claude Code terminal. Expected output is given for each step; anything else is a finding to report back.

Sections marked **(after phase N)** become meaningful once that phase is committed; the commands still run before then but show fewer components.

## 0. Prerequisites

```bash
claude --version          # expected: 2.1.224 or newer
jq --version              # expected: jq-1.7 or newer (hooks and adapters depend on jq)
git --version
```

## 1. Validate the manifests (same check the build ran)

From the repository root:

```bash
claude plugin validate . --strict
claude plugin validate plugins/ai-sdlc --strict
```

Expected, twice:

```
✔ Validation passed
```

## 2. Add the marketplace from the local checkout and install

Inside a Claude Code session started in **any** directory:

```
/plugin marketplace add C:\Projects\ai-sdlc
```

Expected: a confirmation naming the marketplace `ai-sdlc-kit` with one plugin, `ai-sdlc`. Then:

```
/plugin install ai-sdlc@ai-sdlc-kit
```

Expected: install succeeds and asks you to restart (or run `/reload-plugins`). After restart:

```bash
claude plugin list
```

Expected: a line containing `ai-sdlc@ai-sdlc-kit` marked enabled, version `0.1.0` (the version in `plugins/ai-sdlc/.claude-plugin/plugin.json` at the time you installed).

Alternative for a quick check without touching the marketplace registry:

```bash
claude --plugin-dir C:\Projects\ai-sdlc\plugins\ai-sdlc
```

## 3. Confirm the components registered

```bash
claude plugin details ai-sdlc@ai-sdlc-kit
```

Expected (after phase 1): `commands: sdlc-status`. Expected (after phase 7): every entry below, each namespaced `ai-sdlc:`.

| Kind | Names |
| --- | --- |
| commands | `sdlc-init`, `sdlc-status`, `sdlc-upgrade`, `sdlc-start`, `sdlc-publish`, `sdlc-verify`, `sdlc-ship`, `sdlc-postmortem`, `sdlc-metrics-baseline`, `sdlc-metrics-report` |
| skills | `sdlc-loop`, `sdlc-platform`, `sdlc-publish`, `sdlc-ship`, `sdlc-postmortem`, `sdlc-metrics`, `sdlc-security-review` |
| agents | `sdlc-verifier`, `sdlc-security-auditor`, `sdlc-metrics-analyst` |
| hooks | `PreToolUse` × 5 matcher groups, `PostToolUse` × 1 (after phase 5) |

In an interactive session, typing `/ai-sdlc:` should autocomplete the commands and skills above.

## 4. Confirm every hook registers with `${CLAUDE_PLUGIN_ROOT}` resolved **(after phase 5)**

Start a session in an **sdlc project** (for example the scratch repo produced in `.dev/scratch/gh`, or any repo where you ran `/ai-sdlc:sdlc-init`) with a debug file, ask for one harmless edit, then exit:

```bash
cd C:\Projects\ai-sdlc\.dev\scratch\gh
claude --debug-file .sdlc-debug.txt -p "Append the line 'verify' to NOTES.md and stop."
grep -E 'guard-secrets|guard-protected-paths|guard-test-edits|guard-verifier-readonly|post-edit-verify|gate-production' .sdlc-debug.txt | head -20
grep -c 'CLAUDE_PLUGIN_ROOT}' .sdlc-debug.txt
```

Expected:

- The first `grep` prints hook lines whose command paths start with an absolute path under `C:\Users\<you>\.claude\plugins\cache\ai-sdlc-kit\ai-sdlc\<version>\hooks\` (or the `/c/Users/...` spelling).
- The second `grep` prints `0`: no line still contains the literal, unexpanded `${CLAUDE_PLUGIN_ROOT}`.
- No line reads `hook error` or `No such file or directory`.

Delete `.sdlc-debug.txt` afterwards; it can contain file contents.

## 5. Confirm an unrelated repo produces zero hook output and no startup delay **(after phase 5)**

Pick any repository that has **no** `sdlc.config.json`.

```bash
cd C:\Projects\<some-unrelated-repo>
claude --debug-file .sdlc-debug.txt -p "Append the line 'verify' to NOTES.md, then delete that line again, and stop."
grep -E 'hook error|BLOCKED|sdlc' .sdlc-debug.txt | grep -v 'ai-sdlc-kit\\ai-sdlc\\' | head
```

Expected: the `grep` prints nothing. The transcript shows no hook messages of any kind. Every `ai-sdlc` hook exits 0 before reading its input because `sdlc.config.json` is absent.

Startup delay: run each command three times and compare the wall clock.

```bash
time claude -p "reply with the single word ok"
claude plugin disable ai-sdlc@ai-sdlc-kit
time claude -p "reply with the single word ok"
claude plugin enable ai-sdlc@ai-sdlc-kit
```

Expected: the difference between enabled and disabled is within run-to-run noise (well under one second). Hooks do not run at startup; they run per tool call, and in a non-sdlc repo each exits in the time it takes bash to start.

## 6. Uninstall (to leave your machine as it was)

```
/plugin uninstall ai-sdlc@ai-sdlc-kit
/plugin marketplace remove ai-sdlc-kit
```

Expected: both succeed; `claude plugin list` no longer shows `ai-sdlc`.
