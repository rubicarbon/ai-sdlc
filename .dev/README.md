# `.dev/` — build-session controls for this repository

This directory holds material for developing `ai-sdlc-kit` itself. Nothing here ships in the plugin.

## Repository boundary restriction

The build session that created this repo was not allowed to touch the filesystem outside the repo root. Two independent controls enforce that:

1. **Permission deny rules** in `.claude/settings.json` deny `Read`/`Edit` on the home directory, `C:\Users`, `/tmp`, Windows system directories and the `D:` drive. Rules cannot express "everything except this repo" (deny beats allow, no negation), so they only name known outside roots.
2. **`PreToolUse` hook** `.claude/hooks/guard-repo-boundary.sh` resolves the target path of every `Read`, `Edit`, `Write`, `NotebookEdit`, `Glob`, `Grep`, `Bash` and `PowerShell` call and exits 2 when the resolved absolute path is not under the repo root. It tracks `cd`/`pushd`/`Set-Location` across `&&`, `;`, `|`, subshells and backticks; rejects `~`, `$HOME`, `%USERPROFILE%`, `$env:*`, `$TEMP` and friends; collapses `..`; follows symlinks with `realpath`; and understands Windows drive paths and UNC paths. `git -C`, `git --git-dir`, `git worktree add` and `git clone <url> <dir>` are covered by the generic path-argument check.

Run the unit tests with:

```bash
bash .dev/boundary-tests.sh
```

### Kill switch

Creating the file `.dev/BOUNDARY_HOOK_DISABLED` makes the hook exit 0 with a loud warning on stderr. It exists only so the permission deny rules can be proven to block independently of the hook. It is gitignored. Delete it as soon as the proof is done.

### Known limits

- Paths constructed at runtime (base64, `eval` of computed strings, paths built by a script) are not visible to the hook.
- `@file` mentions in a prompt do not go through `PreToolUse`; only the deny rules cover them.
- The hook runs in subagents too (hooks are inherited), but a subagent started with a different `cwd` is denied wholesale.
- The Claude Code scratchpad directory offered by the harness lives outside the repo and is blocked by design. Use `.dev/scratch/` (gitignored) instead.

## Scratch space

`.dev/scratch/` is gitignored and holds `/sdlc-init` dry-run repositories, adapter mock output and other throwaway material.

## `VERIFY.md`

Steps that only the repository owner can run (plugin install from the marketplace, `claude --debug-file` hook registration check, unrelated-repo silence check) are written to `.dev/VERIFY.md` with exact commands and expected output.
